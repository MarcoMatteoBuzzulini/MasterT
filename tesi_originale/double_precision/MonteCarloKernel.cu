/*
 * MonteCarloKernel.cu
 *
 *  Created on: 06/feb/2018
 *  Author: marco
 */

#include <curand.h>
#include <curand_kernel.h>
#include "MonteCarlo.h"

// Struct for Monte Carlo methods
typedef struct{
	OptionValue *h_CallValue, *d_CallValue;
	OptionValue callValue;
	MultiOptionData option;
    curandState *RNG;
    int numBlocks, numThreads, numOpt, path;
} dev_MonteCarloData;

/*
 * Error handling from Cuda programming - shane cook
 */
void cuda_error_check(const char * prefix, const char * postfix){
	if (cudaPeekAtLastError() != cudaSuccess){
		printf("\n%s%s%s", prefix, cudaGetErrorString(cudaGetLastError()), postfix);
		cudaDeviceReset();
		//wait_exit();
		exit(1);
	}
}

// Inizializzazione per Monte Carlo da svolgere una volta sola
void MonteCarlo_init(dev_MonteCarloData *data);
// Liberazione della memoria da svolgere una volta sola
void MonteCarlo_free(dev_MonteCarloData *data);
// Metodo Monte Carlo
void MonteCarlo(dev_MonteCarloData *data);

__device__ __constant__ MultiOptionData OPTION;
__device__ __constant__ int N_OPTION, N_PATH;

__device__ void brownianVect(double *bt, curandState threadState){
	int i,j;
	double g[N];
	for(i=0;i<N_OPTION;i++)
		g[i]=curand_normal(&threadState);
	for(i=0;i<N_OPTION;i++){
		double somma = 0;
		for(j=0;j<N_OPTION;j++)
			somma += OPTION.p[i][j] * g[j];
		bt[i] = somma;
	}
	for(i=0;i<N_OPTION;i++)
		bt[i] += OPTION.d[i];
}

__device__ double blackScholes(double *bt){
	int j;
	double s[N], st_sum=0, price;
    for(j=0;j<N_OPTION;j++){
        double geomBt = (OPTION.r - 0.5 * OPTION.v[j] * OPTION.v[j])*OPTION.t + OPTION.v[j] * bt[j] * sqrt(OPTION.t);
	     s[j] = OPTION.s[j] * exp(geomBt);
    }
	// Third step: Mean price
	for(j=0;j<N_OPTION;j++)
		st_sum += s[j] * OPTION.w[j];
	// Fourth step: Option payoff
	price = st_sum - OPTION.k;

    return (price>0)?(price):(0);
}

__global__ void MultiMCBasketOptKernel(curandState * randseed, OptionValue *d_CallValue){
    int i;
    // Parameters for shared memory
    int sumIndex = threadIdx.x;
    int sum2Index = sumIndex + blockDim.x;
    // Parameter for reduction
    int blockIndex = blockIdx.x;

    /*------------------ SHARED MEMORY DICH ----------------*/
    extern __shared__ double s_Sum[];

    // Global thread index
    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    // Copy random number state to local memory
    curandState threadState = randseed[tid];

    OptionValue sum = {0, 0};

    for( i=sumIndex; i<N_PATH; i+=blockDim.x){
    	double price=0.0f, bt[N];
    	// Random Number Generation
   		brownianVect(bt,threadState);
   		// Price simulation with the Black&Scholes payoff function
        price=blackScholes(bt);

        sum.Expected += price;
        sum.Confidence += price*price;
    }
    // Copy to the shared memory
    s_Sum[sumIndex] = sum.Expected;
    s_Sum[sum2Index] = sum.Confidence;
    __syncthreads();
    // Reduce shared memory accumulators and write final result to global memory
    int halfblock = blockDim.x/2;
    // Reduction in log2(threadBlocks) steps, so threadBlock must be power of 2
    do{
        if ( sumIndex < halfblock ){
            s_Sum[sumIndex] += s_Sum[sumIndex+halfblock];
            s_Sum[sum2Index] += s_Sum[sum2Index+halfblock];
        }
        __syncthreads();
        halfblock /= 2;
    }while ( halfblock != 0 );
    if (sumIndex == 0){
    		d_CallValue[blockIndex].Expected = s_Sum[sumIndex];
    		d_CallValue[blockIndex].Confidence = s_Sum[sum2Index];
    }
}

__global__ void randomSetup( curandState *randSeed ){
    // Global thread index
    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    // Each thread block gets different seed, threads within a thread block get different sequence numbers
    curand_init(blockIdx.x + gridDim.x, threadIdx.x, 0, &randSeed[tid]);
}

void MonteCarlo_init(dev_MonteCarloData *data){
	cudaEvent_t start, stop;
	CudaCheck( cudaEventCreate( &start ));
    CudaCheck( cudaEventCreate( &stop ));
    float time;

    int n_option = data->numOpt;
    int n_path = data->path;

    /*--------------- CONSTANT MEMORY ----------------*/
    CudaCheck(cudaMemcpyToSymbol(N_OPTION,&n_option,sizeof(int)));
    CudaCheck(cudaMemcpyToSymbol(N_PATH,&n_path,sizeof(int)));

	// RANDOM NUMBER GENERATION KERNEL
	//Allocate states for pseudo random number generators
	CudaCheck(cudaMalloc((void **) &data->RNG, data->numBlocks * data->numThreads * sizeof(curandState)));
	//Setup for the random number sequence
    CudaCheck( cudaEventRecord( start, 0 ));
    randomSetup<<<data->numBlocks, data->numThreads>>>(data->RNG);
    cuda_error_check("\Errore nel lancio randomSetup: ","\n");
    CudaCheck( cudaEventRecord( stop, 0));
    CudaCheck( cudaEventSynchronize( stop ));
    CudaCheck( cudaEventElapsedTime( &time, start, stop ));
    printf( "RNG done in %f milliseconds\n", time);

    //	Host Memory Allocation
    CudaCheck(cudaMallocHost(&data->h_CallValue, sizeof(OptionValue)*data->numBlocks));
    //	Device Memory Allocation
    CudaCheck(cudaMalloc(&data->d_CallValue, sizeof(OptionValue)*data->numBlocks));

    CudaCheck( cudaEventDestroy( start ));
    CudaCheck( cudaEventDestroy( stop ));
}

void MonteCarlo_free(dev_MonteCarloData *data){
	//Free memory space
	CudaCheck(cudaFree(data->RNG));
    CudaCheck(cudaFreeHost(data->h_CallValue));
    CudaCheck(cudaFree(data->d_CallValue));
}

void MonteCarlo(dev_MonteCarloData *data){
	/*--------------- CONSTANT MEMORY ----------------*/
	CudaCheck(cudaMemcpyToSymbol(OPTION,&data->option,sizeof(MultiOptionData)));

	/*----------------- SHARED MEMORY -------------------*/
	int i, numShared = sizeof(double) * data->numThreads * 2;

	MultiMCBasketOptKernel<<<data->numBlocks, data->numThreads, numShared>>>(data->RNG,(OptionValue *)(data->d_CallValue));
	cuda_error_check("\Errore nel lancio MultiMCBasketOptKernel: ","\n");

	//MEMORY CPY: prices per block
	CudaCheck(cudaMemcpy(data->h_CallValue, data->d_CallValue, data->numBlocks * sizeof(OptionValue), cudaMemcpyDeviceToHost));

	// Closing Monte Carlo
	long double sum=0, sum2=0, price, empstd;
    long int nSim = data->numBlocks * data->path;
    for ( i = 0; i < data->numBlocks; i++ ){
    	sum += data->h_CallValue[i].Expected;
	    sum2 += data->h_CallValue[i].Confidence;
	}
	price = exp(-(data->option.r*data->option.t)) * (sum/(double)nSim);
    empstd = sqrt((double)((double)nSim * sum2 - sum * sum)/((double)nSim * (double)(nSim - 1)));
    data->callValue.Confidence = 1.96 * empstd / (double)sqrt((double)nSim);
    data->callValue.Expected = price;
}

extern "C" OptionValue dev_basketOpt(MultiOptionData *option, int numBlocks, int numThreads, int sims){
	dev_MonteCarloData data;
	    data.option = *option;
	    data.numBlocks = numBlocks;
	    data.numThreads = numThreads;
	    data.numOpt = N;
	    data.path = sims / numBlocks;

    MonteCarlo_init(&data);
    MonteCarlo(&data);
    MonteCarlo_free(&data);

    return data.callValue;
}

extern "C" OptionValue dev_vanillaOpt(OptionData *opt, int numBlocks, int numThreads, int sims){
	MultiOptionData option;
		option.w[0] = 1;
		option.d[0] = 0;
		option.p[0][0] = 1;
		option.s[0] = opt->s;
		option.v[0] = opt->v;
		option.k = opt->k;
		option.r = opt->r;
		option.t = opt->t;

    dev_MonteCarloData data;
    	data.option = option;
    	data.numBlocks = numBlocks;
    	data.numThreads = numThreads;
    	data.numOpt = 1;
    	data.path = sims / numBlocks;

    MonteCarlo_init(&data);
    MonteCarlo(&data);
    MonteCarlo_free(&data);

    return data.callValue;
}

extern "C" void dev_cvaEquityOption(CVA *cva, int numBlocks, int numThreads, int sims){
    int i;
    double dt = cva->opt.t / (double)cva->n;

    dev_MonteCarloData data;
    // Option
    data.option = cva->opt;
    // Kernel parameters
    data.numBlocks = numBlocks;
    data.numThreads = numThreads;
    data.numOpt = N;
    data.path = sims / numBlocks;

    MonteCarlo_init(&data);

    // Original option price
    MonteCarlo(&data);
    cva->ee[0] = data.callValue;

    // Expected Exposures (ee), Default probabilities (dp,fp)
    double sommaProdotto1=0;
    //double sommaProdotto2=0;
	for( i=1; i < (cva->n+1); i++){
		if((data.option.t -= (dt))<0){
			cva->ee[i].Confidence = 0;
			cva->ee[i].Expected = 0;
		}
		else{
			MonteCarlo(&data);
			cva->ee[i] = data.callValue;
		}
        cva->dp[i] = exp(-(dt*i) * cva->defInt) - exp(-(dt*(i+1)) * cva->defInt);
		//cva->fp[i] = exp(-(dt)*(i-1) * cva->credit.fundingspread / 100 / cva->credit.lgd) - exp(-(dt*i) * cva->credit.fundingspread / 100 / cva->credit.lgd );
        sommaProdotto1 += cva->ee[i].Expected * cva->dp[i];
		//sommaProdotto2 += cva->ee[i].Expected * cva->fp[i];
	}
	// CVA and FVA
	cva->cva = sommaProdotto1 * cva->lgd;
	//cva->fva = -sommaProdotto2*cva->credit.lgd;

	// Closing
	MonteCarlo_free(&data);
}
