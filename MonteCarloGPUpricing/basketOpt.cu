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

extern "C" OptionValue host_basketOpt(MultiOptionData*, int);
extern "C" OptionValue dev_basketOpt(MultiOptionData *, int, int);

///////////////////////////////////
//	PRINT FUNCTIONS
///////////////////////////////////
void printVect( double *mat, int c ){
    int i,j,r=1;
    for(i=0; i<r; i++){
        printf("\n!\t");
        for(j=0; j<c; j++){
            printf("\t%f\t",mat[j+i*c]);
        }
        printf("\t!");
    }
    printf("\n\n");
}

void printOption( OptionData o){
    printf("\n-\tOption data\t-\n\n");
    printf("Underlying asset price:\t € %.2f\n", o.s);
    printf("Strike price:\t\t € %.2f\n", o.k);
    printf("Risk free interest rate: %.2f %%\n", o.r * 100);
    printf("Volatility:\t\t\t %.2f %%\n", o.v * 100);
    printf("Time to maturity:\t\t %.2f %s\n", o.t, (o.t>1)?("years"):("year"));
}

void printMat( double *mat, int r, int c ){
    int i,j;
    for(i=0; i<r; i++){
        printf("\n!\t");
        for(j=0; j<c; j++){
            printf("\t%f\t",mat[j+i*c]);
        }
        printf("\t!");
    }
    printf("\n\n");
}

void printMultiOpt( MultiOptionData *o){
    printf("\n-\tBasket Option data\t-\n\n");
    printf("Number of assets: %d\n",N);
    printf("Underlying assets prices:\n");
    printVect(o->s, N);
    printf("Volatility:\n");
    printVect(o->v, N);
    printf("Weights:");
    printVect(o->w, N);
    printf("Correlation matrix:\n");
    printMat(&o->p[0][0], N, N);
    printf("Strike price:\t € %.2f\n", o->k);
    printf("Risk free interest rate: %.2f \n", o->r);
    printf("Time to maturity:\t %.2f %s\n", o->t, (o->t>1)?("years"):("year"));
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
	*numThreads = pow(2,(int)(log(cudaCoresPM)/log(2)))*2;
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

void Parameters(int *numBlocks, int *numThreads){
		cudaDeviceProp deviceProp;
		CudaCheck(cudaGetDeviceProperties(&deviceProp, 0));
		numThreads[0] = 128;
		numThreads[1] = 256;
		numThreads[2] = 512;
		numThreads[3] = 1024;
		printf("\nParametri CUDA:\n");
		printf("Scegli il numero di Blocchi: ");
		scanf("%d",numBlocks);
}

////////////////////////////////////////////////////////////////////////////////////////
//                                      MAIN
////////////////////////////////////////////////////////////////////////////////////////

int main(int argc, const char * argv[]) {
    /*--------------------------- VARIABLES -----------------------------------*/
	double dw = (double)1 / N;

	// Option Data
	MultiOptionData option;
	//	Volatility
	option.v[0] = 0.2;
	option.v[1] = 0.3;
	option.v[2] = 0.2;
	//	Spot prices
	option.s[0] = 100;
	option.s[1] = 100;
	option.s[2] = 100;
	//	Weights
	option.w[0] = dw;
	option.w[1] = dw;
	option.w[2] = dw;
	//	Correlations
	option.p[0][0] = 1;
			option.p[0][1] = -0.5;
					option.p[0][2] = -0.5;
	option.p[1][0] = -0.5;
			option.p[1][1] = 1;
					option.p[1][2] = -0.5;
	option.p[2][0] = -0.5;
			option.p[2][1] = -0.5;
					option.p[2][2] = 1;
	//	Drift vectors for the brownians
	option.d[0] = 0;
	option.d[1] = 0;
	option.d[2] = 0;
	option.k= 100.f;
	option.r= 0.048790164;
	option.t= 1.f;

	// Simulation variables
	int numBlocks, numThreads[THREADS], SIMS, i, j;
	OptionValue CPU_sim, GPU_sim[THREADS];
	float CPU_timeSpent=0, GPU_timeSpent[THREADS], speedup[THREADS];
	double cholRho[N][N], d_price, h_price, difference[THREADS];
	// Timer
	// clock_t h_start, h_stop;
	cudaEvent_t d_start, d_stop;

	/*--------------------------- START PROGRAM -----------------------------------*/
	printf("Basket Option Pricing\n");
	//	CUDA parameters for parallel execution
	Parameters(&numBlocks, numThreads);
	printf("Simulazione di ( %d ; %d )\n",numBlocks, numThreads);
	SIMS = numBlocks*PATH;
	//	Print Option details
	printMultiOpt(&option);
    //	Cholevski factorization
    Chol(option.p, cholRho);
    for(i=0;i<N;i++)
    	for(j=0;j<N;j++)
           	option.p[i][j]=cholRho[i][j];
    // Timer init
    CudaCheck( cudaEventCreate( &d_start ));
    CudaCheck( cudaEventCreate( &d_stop ));
    /* CPU Monte Carlo */
    printf("\nMonte Carlo execution on CPU:\nN^ simulations: %d\n\n",SIMS);
    //h_start = clock();
    CudaCheck( cudaEventRecord( d_start, 0 ));
    CPU_sim=host_basketOpt(&option, SIMS);
    //h_stop = clock();
    //CPU_timeSpent = ((float)(h_stop - h_start)) / CLOCKS_PER_SEC;
    CudaCheck( cudaEventRecord( d_stop, 0));
    CudaCheck( cudaEventSynchronize( d_stop ));
    CudaCheck( cudaEventElapsedTime( &CPU_timeSpent, d_start, d_stop ));
    CPU_timeSpent /= CLOCKS_PER_SEC;
    h_price = CPU_sim.Expected;

    // GPU Monte Carlo
    printf("\nMonte Carlo execution on GPU:\nN^ simulations: %d\n",SIMS);
    for(i=0; i<THREADS; i++){
    	CudaCheck( cudaEventRecord( d_start, 0 ));
       	GPU_sim[i] = dev_basketOpt(&option, numBlocks, numThreads[i])
        CudaCheck( cudaEventRecord( d_stop, 0));
        CudaCheck( cudaEventSynchronize( d_stop ));
        CudaCheck( cudaEventElapsedTime( &GPU_timeSpent[i], d_start, d_stop ));
        GPU_timeSpent[i] /= 1000;
        difference[i] = abs(GPU_sim[i].Expected - h_price);
        speedup[i] = abs(CPU_timeSpent / GPU_timeSpent[i]);
    }
    // Comparing time spent with the two methods
    printf( "\n-\tResults:\t-\n");
    printf("Simulated price for the option with CPU: € %f with I.C. %f\n", h_price, CPU_sim.Confidence);
    printf("Total execution time CPU: %f s with device function\n\n", CPU_timeSpent);
    printf("Simulated price for the option with GPU:\n");
    printf("  : NumThreads : Price : Confidence Interval : Difference from CPU price :  Time : Speedup :");
    printf("\n");
    for(i=0; i<THREADS; i++){
        	printf(": \t %d ",numThreads[i]);
        	printf(" \t %f ",GPU_sim[i].Expected);
        	printf(" \t %f  ",GPU_sim[i].Confidence);
        	printf(" \t %f \t",difference[i]);
        	printf(" \t %f ",GPU_timeSpent[i]);
        	printf(" \t %.2f \t",speedup[i]);
        	printf(":\n");
    }
    CudaCheck( cudaEventDestroy( d_start ));
    CudaCheck( cudaEventDestroy( d_stop ));
    return 0;
}

void Chol( double c[N][N], double a[N][N] ){
    int i,j,k;
    double v[N];
    for( i=0; i<N; i++){
        for( j=0; j<N; j++ ){
            if( j>=i ){
                //Triangolare inferiore
            	//v[j]=c[j][i]
            	v[j]=c[j][i];
                for(k=0; k<i; k++)    //Scorre tutta
                    //v[j] = v[j] - a[i][k] * a[j][k]
                    v[j] = v[j] - a[i][k] * a[j][k];
                //a[j][i] = v[j] / sqrt( v[i] )
                if(v[i]>0)
                	a[j][i] = v[j] / sqrt( v[i] );
                else
                	a[j][i] = 0.0f;
            }
            else
                //Triangolare superiore a[j][i]
            	a[j][i] = 0.0f;
        }
    }
}
