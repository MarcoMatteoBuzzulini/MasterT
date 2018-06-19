//
//  MonteCarlo.cu
//  tesi
//
//  Created by Marco Matteo Buzzulini on 27/11/17.
//  Copyright © 2017 Marco Matteo Buzzulini. All rights reserved.
//

#include "MonteCarlo.h"

extern "C" OptionValue host_basketOpt(MultiOptionData*, int);
extern "C" OptionValue dev_basketOpt(MultiOptionData *, int, int);
extern "C" void Chol( double c[N][N], double a[N][N] );
extern "C" void printMultiOpt( MultiOptionData *o);
extern "C" double randMinMax(double min, double max);
//extern "C" void Parameters(int *numBlocks, int *numThreads);

void getRandomSigma( double* std );
void getRandomRho( double* rho );
void pushVett( double* vet, double x );

void Parameters(int *numBlocks, int *numThreads);
void memAdjust(cudaDeviceProp *deviceProp, int *numThreads);
void sizeAdjust(cudaDeviceProp *deviceProp, int *numBlocks, int *numThreads);

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

	if(N!=3){
		srand((unsigned)time(NULL));
		getRandomSigma(option.v);
		getRandomRho(&option.p[0][0]);
		pushVett(option.s,100);
		pushVett(option.w,dw);
		pushVett(option.d,0);
	}

	// Simulation variables
	int numBlocks, numThreads[THREADS], SIMS, i, j;
	OptionValue CPU_sim, GPU_sim[THREADS];
	float CPU_timeSpent=0, GPU_timeSpent[THREADS], speedup[THREADS];
	double cholRho[N][N], difference[THREADS];
	// Timer
	// clock_t h_start, h_stop;
	cudaEvent_t d_start, d_stop;

	/*--------------------------- START PROGRAM -----------------------------------*/
	printf("Basket Option Pricing\n");
	//	CUDA parameters for parallel execution
	Parameters(&numBlocks, numThreads);
	SIMS = numBlocks*PATH;
	printf("\nScenari di Monte Carlo: %d\n",SIMS);
	//	Print Option details
	if(N<7)
		printMultiOpt(&option);
	else
		printf("\nBasket Option con %d sottostanti\n",N);
    //	Cholevski factorization
    Chol(option.p, cholRho);
    for(i=0;i<N;i++)
    	for(j=0;j<N;j++)
           	option.p[i][j]=cholRho[i][j];
    // Timer init
    CudaCheck( cudaEventCreate( &d_start ));
    CudaCheck( cudaEventCreate( &d_stop ));
    /* CPU Monte Carlo */
    printf("\nMonte Carlo execution on CPU:\nN^ simulations: %d\n",SIMS);
    //h_start = clock();
    CudaCheck( cudaEventRecord( d_start, 0 ));
    CPU_sim=host_basketOpt(&option, SIMS);
    //h_stop = clock();
    //CPU_timeSpent = ((float)(h_stop - h_start)) / CLOCKS_PER_SEC;
    CudaCheck( cudaEventRecord( d_stop, 0));
    CudaCheck( cudaEventSynchronize( d_stop ));
    CudaCheck( cudaEventElapsedTime( &CPU_timeSpent, d_start, d_stop ));
    CPU_timeSpent /= 1000;

    // GPU Monte Carlo
    printf("\nMonte Carlo execution on GPU:\nN^ simulations: %d\n",SIMS);
    for(i=0; i<THREADS; i++){
    	CudaCheck( cudaEventRecord( d_start, 0 ));
       	GPU_sim[i] = dev_basketOpt(&option, numBlocks, numThreads[i]);
        CudaCheck( cudaEventRecord( d_stop, 0));
        CudaCheck( cudaEventSynchronize( d_stop ));
        CudaCheck( cudaEventElapsedTime( &GPU_timeSpent[i], d_start, d_stop ));
        GPU_timeSpent[i] /= 1000;
        difference[i] = abs(GPU_sim[i].Expected - CPU_sim.Expected);
        speedup[i] = abs(CPU_timeSpent / GPU_timeSpent[i]);
    }
    // Comparing time spent with the two methods
    printf( "\n-\tResults:\t-\n");
    printf( "CPU:\n");
    printf("\tSimulated price: € %f with I.C. %f\n", CPU_sim.Expected, CPU_sim.Confidence);
    printf("\tExecution time: %f s (with device function)\n\n", CPU_timeSpent);
    printf("GPU:\n");
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

//////////////////////////////////////////////////////
//    FUNCTIONS
//////////////////////////////////////////////////////////////

//Simulation std, rho and covariance matrix
void getRandomSigma( double* std ){
    int i;
    for(i=0;i<N;i++)
        std[i] = randMinMax(0, 1);
}
void getRandomRho( double* rho ){
    int i,j;
    //creating the vectors of rhos
    for(i=0;i<N;i++){
        for(j=i;j<N;j++){
            double r;
            if(i==j)
                r=1;
            else
                r=randMinMax(-1, 1);
            rho[j+i*N] = r;
            rho[i+j*N] = r;
        }
    }
}
void pushVett( double* vet, double x ){
    int i;
    for(i=0;i<N;i++)
        vet[i] = x;
}
///////////////////////////////////
//    ADJUST FUNCTIONS
///////////////////////////////////

void sizeAdjust(cudaDeviceProp *deviceProp, int *numBlocks, int *numThreads){
    int maxGridSize = deviceProp->maxGridSize[0];
    int maxBlockSize = deviceProp->maxThreadsPerBlock;
    //    Replacing in case of wrong size
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

void Parameters(int *numBlocks, int *numThreads){
    cudaDeviceProp deviceProp;
    int i = 0;
    CudaCheck(cudaGetDeviceProperties(&deviceProp, 0));
    numThreads[0] = 128;
    numThreads[1] = 256;
    numThreads[2] = 512;
    numThreads[3] = 1024;
    printf("\nParametri CUDA:\n");
    printf("Scegli il numero di Blocchi: ");
    scanf("%d",numBlocks);
    for (i=0; i<THREADS; i++) {
        sizeAdjust(&deviceProp,numBlocks, &numThreads[i]);
        memAdjust(&deviceProp, &numThreads[i]);
    }
}
