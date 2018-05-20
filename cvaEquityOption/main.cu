//
//  MonteCarlo.cu
//  tesi
//
//  Created by Marco Matteo Buzzulini on 27/11/17.
//  Copyright © 2017 Marco Matteo Buzzulini. All rights reserved.
//

#include "MonteCarlo.h"
#include <cuda_runtime.h>

// includes, project
#include <helper_functions.h> // Helper functions (utilities, parsing, timing)
#include <helper_cuda.h>      // helper functions (cuda error checking and initialization)
#include <multithreading.h>

//	Host Black & Scholes
extern "C" double host_bsCall ( OptionData );

//	Host MonteCarlo
extern "C" OptionValue host_vanillaOpt(OptionData, int);

//	Device MonteCarlo
extern "C" OptionValue dev_vanillaOpt(OptionData *, int, int);

//	CVA: per ora è in test la simulazione delle Expected Exposures
extern "C" void dev_cvaEquityOption(OptionValue*, OptionData, CreditData, int, int, int);


///////////////////////////////////
//	PRINT FUNCTIONS
///////////////////////////////////

void printOption( OptionData o){
    printf("\n-\tOption data\t-\n\n");
    printf("Underlying asset price:\t € %.2f\n", o.s);
    printf("Strike price:\t\t € %.2f\n", o.k);
    printf("Risk free interest rate: %.2f\n", o.r);
    printf("Volatility:\t\t %.2f\n", o.v);
    printf("Time to maturity:\t %.2f %s\n", o.t, (o.t>1)?("years"):("year"));
}


///////////////////////////////////
//	ADJUST FUNCTIONS
///////////////////////////////////

void sizeAdjust(cudaDeviceProp *deviceProp, int *numBlocks, int *numThreads){
	int maxGridSize = deviceProp->maxGridSize[0];
	int maxBlockSize = deviceProp->maxThreadsPerBlock;
	//	Replacing in case of wrong size
	if(*numBlocks > maxGridSize){
		*numBlocks = maxGridSize;
		printf("Warning: maximum size of Grid is %d",*numBlocks);
	}
	if(*numThreads > maxBlockSize){
		*numThreads = maxBlockSize;
		printf("Warning: maximum size of Blocks is %d",*numThreads);
	}
}

void memAdjust(cudaDeviceProp *deviceProp, int *numThreads){
		size_t maxShared = deviceProp->sharedMemPerBlock;
		size_t maxConstant = deviceProp->totalConstMem;
		int sizeDouble = sizeof(double);
		int numShared = sizeDouble * *numThreads * 2;
		if(sizeof(MultiOptionData) > maxConstant){
			printf("\nWarning: Excess use of constant memory: %zu\n",maxConstant);
			printf("A double variable size is: %d\n",sizeDouble);
			printf("In a MultiOptionData struct there's a consumption of %zu constant memory\n",sizeof(MultiOptionData));
			printf("In this Basket Option there's %d stocks\n",N);
			int maxDim = (int)maxConstant/(sizeDouble*5);
			printf("The optimal number of dims should be: %d stocks\n",maxDim);
		}
		if(numShared > maxShared){
			printf("\nWarning: Excess use of shared memory: %zu\n",maxShared);
			printf("A double variable size is: %d\n",sizeDouble);
			int maxThreads = (int)maxShared / (2*sizeDouble);
			printf("The optimal number of thread should be: %d\n",maxThreads);
		}
		printf("\n");
}

void optimalAdjust(cudaDeviceProp *deviceProp, int *numBlocks, int *numThreads){
	int multiProcessors = deviceProp->multiProcessorCount;
	int cudaCoresPM = _ConvertSMVer2Cores(deviceProp->major, deviceProp->minor);
	*numBlocks = multiProcessors * 40;
	*numThreads = pow(2,(int)(log(cudaCoresPM)/log(2)));
	sizeAdjust(deviceProp,numBlocks, numThreads);
}

void choseParameters(int *numBlocks, int *numThreads){
		cudaDeviceProp deviceProp;
		CudaCheck(cudaGetDeviceProperties(&deviceProp, 0));
		char risp;
		printf("\nParametri CUDA:\n");
		printf("Scegli il numero di Blocchi: ");
		scanf("%d",numBlocks);
		printf("Scegli il numero di Threads per blocco: ");
		scanf("%d",numThreads);
		printf("Vuoi ottimizzare i parametri inseriti? (Y/N) ");
		scanf("%s",&risp);
		if((risp=='Y')||(risp=='y'))
			optimalAdjust(&deviceProp,numBlocks, numThreads);
		else
			sizeAdjust(&deviceProp,numBlocks, numThreads);
		memAdjust(&deviceProp,numThreads);
}

////////////////////////////////////////////////////////////////////////////////////////
//                                      MAIN
////////////////////////////////////////////////////////////////////////////////////////

int main(int argc, const char * argv[]) {
    /*--------------------------- DATA INSTRUCTION -----------------------------------*/
	OptionData option;
	option.v = 0.25;
	option.s = 100;
	option.k= 100.f;
	option.r= 0.05;
	option.t= 1.f;

	CreditData credit = {0,0,0};

	printf("Expected Exposures of an Equity Option\n");

	//	Definizione dei parametri CUDA per l'esecuzione in parallelo
	int numBlocks, numThreads;
	choseParameters(&numBlocks, &numThreads);

	printf("Simulazione di ( %d ; %d )\n",numBlocks, numThreads);
	int SIMS = numBlocks*PATH;

	//	Print Option details
	printOption(option);

	// PARAMETRI PER LA SIMULAZIONE EE
	// Scelta da tastiera del numero di simulazioni: di default 40
	int n = 40, i;
	double dt = option.t/(double)n;

    /*---------------- CORE COMPUTATIONS ----------------*/
	// Puntatore al vettore di prezzi simulati
    OptionValue *GPU_sim = (OptionValue *)malloc(sizeof(OptionValue)*n);
    
    float CPU_timeSpent=0, GPU_timeSpent=0, speedup;
    double *price = (double*)malloc(sizeof(double)*n);
    double *bs_price = (double*)malloc(sizeof(double)*n);
    double difference;

    clock_t h_start, h_stop;
    cudaEvent_t d_start, d_stop;
    CudaCheck( cudaEventCreate( &d_start ));
    CudaCheck( cudaEventCreate( &d_stop ));

    //	Black & Scholes price
    for(i=0;i<n;i++){
    	bs_price[i] = host_bsCall(option);
    	option.t -= dt;
    }

    //	Ripristino valore originale del Time to mat
    option.t= 1.f;

   	printf("\nPrezzi Black & Scholes:\n");
   	printf("|\ti\t|\tPrezzo\t|\n");
   	for(i=0;i<n;i++)
   		printf("|\t%d\t|\t%f\t|\n",i,bs_price[i]);

    // CPU Monte Carlo
    /*
    printf("\nMonte Carlo execution on CPU:\nN^ simulations: %d\n\n",SIMS);
    h_start = clock();
    CPU_sim=host_vanillaOpt(option, SIMS);
    h_stop = clock();
    CPU_timeSpent = ((float)(h_stop - h_start)) / CLOCKS_PER_SEC;
    
    price = CPU_sim.Expected;
    printf("Simulated price for the basket option: € %f with I.C [ %f;%f ]\n", price, price - CPU_sim.Confidence, price + CPU_sim.Confidence);
    printf("Total execution time: %f s\n\n", CPU_timeSpent);
     */

    // GPU Monte Carlo
    printf("\nMonte Carlo execution on GPU:\nN^ simulations: %d\n",SIMS);
    CudaCheck( cudaEventRecord( d_start, 0 ));
    dev_cvaEquityOption(GPU_sim, option, credit, n, numBlocks, numThreads);
    CudaCheck( cudaEventRecord( d_stop, 0));
    CudaCheck( cudaEventSynchronize( d_stop ));
    CudaCheck( cudaEventElapsedTime( &GPU_timeSpent, d_start, d_stop ));
    GPU_timeSpent /= 1000;
    
    printf("\nPrezzi Simulati:\n");
   	printf("|\ti\t|\Differenza di prezzo\t|\n");
   	for(i=0;i<n;i++)
   		printf("|\t%d\t|\t%f\t|\n",i,GPU_sim[i].Expected);

    printf("Total execution time: %f s\n\n", GPU_timeSpent);
    
    // Comparing time spent with the two methods
    printf( "-\tComparing results:\t-\n");
    printf("\nDifferenza Prezzi:\n");
  	printf("|\ti\t|\tPrezzo\t|");
  	for(i=0;i<n;i++){
  		difference = abs(GPU_sim[i].Expected - bs_price[i]);
   		printf("|\t%d\t|\t%f\t|\n",i,difference);
  	}

    return 0;
}
