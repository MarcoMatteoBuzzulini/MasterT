//
//  MonteCarlo.cu
//  tesi
//
//  Created by Marco Matteo Buzzulini on 27/11/17.
//  Copyright © 2017 Marco Matteo Buzzulini. All rights reserved.
//

#include "MonteCarlo.h"

#define THREADS 256
#define BLOCKS 512
#define PATH 40
#define SIMPB 131072

extern "C" float host_bsCall ( OptionData );
extern "C" void host_cvaEquityOption(CVA *, int);
extern "C" void dev_cvaEquityOption(CVA *, int , int , int );
extern "C" void printOption( OptionData o);
extern "C" void Chol( float c[N][N], float a[N][N] );
extern "C" void printMultiOpt( MultiOptionData *o);
extern "C" float randMinMax(float min, float max);

void getRandomSigma( float* std );
void getRandomRho( float* rho );
void pushVett( float* vet, float x );

const float defInt = 0.03;
const float recoveryRate = 0.4;
const float S = 100;
const float K = 100;
const float R = 0.05;
const float V = 0.2;
const float T = 1.f;

int main(int argc, const char * argv[]) {
    /*--------------------------- DATA INSTRUCTION -----------------------------------*/
    CVA cva;
    cva.defInt = defInt;
    cva.lgd = (1 - recoveryRate);
    cva.n = PATH;
    cva.dp = (float*)malloc((cva.n+1)*sizeof(float));
    //cva.fp = (float*)malloc((cva.n+1)*sizeof(float));

    // n+1 because it starts from 1
    cva.ee = (OptionValue *)malloc(sizeof(OptionValue)*(cva.n+1));
    float *bs_price = (float*)malloc(sizeof(float)*(cva.n+1));

    char risp;
    printf("CVA: %d periodi \nScelta del sottostante:\n(v = opzione call Eu; b = opzione basket con %d sottostanti)\t", PATH, N);
    scanf(" %s",&risp);
    if(risp == 'b'){
        // Option Data
        MultiOptionData opt;
        printf("\nCVA of an European basket Option\nIntensita di default %.2f, LGD %.2f\n",cva.defInt,cva.lgd);
        cva.ns = N;
        float dw = (float)1 / N;
        //    Volatility
        opt.v[0] = 0.2;
        opt.v[1] = 0.3;
        opt.v[2] = 0.2;
        //    Spot prices
        opt.s[0] = 100;
        opt.s[1] = 100;
        opt.s[2] = 100;
        //    Weights
        opt.w[0] = dw;
        opt.w[1] = dw;
        opt.w[2] = dw;
        //    Correlations
        opt.p[0][0] = 1;
        opt.p[0][1] = -0.5;
        opt.p[0][2] = -0.5;
        opt.p[1][0] = -0.5;
        opt.p[1][1] = 1;
        opt.p[1][2] = -0.5;
        opt.p[2][0] = -0.5;
        opt.p[2][1] = -0.5;
        opt.p[2][2] = 1;
        //    Drift vectors for the brownians
        opt.d[0] = 0;
        opt.d[1] = 0;
        opt.d[2] = 0;
        
        opt.k= 100.f;
        opt.r= 0.05;
        opt.t= 1.f;
        
        if(N!=3){
            getRandomSigma(opt.v);
            getRandomRho(&opt.p[0][0]);
            pushVett(opt.s,100);
            pushVett(opt.w,dw);
            pushVett(opt.d,0);
        }
        cva.opt = opt;
    }
    else{
        OptionData opt;
        printf("\nCVA of an European call Option\nIntensita di default %.2f, LGD %.2f\n",cva.defInt,cva.lgd);
        opt.v = V;
        opt.s = S;
        opt.t = T;
        opt.r = R;
        opt.k = K;
        cva.ns = 1;
        cva.option = opt;
    }
    
    cudaEvent_t d_start, d_stop;
    int i, j, SIMS;
    float difference, dt, cholRho[N][N];
    float GPU_timeSpent=0, CPU_timeSpent=0;
    
	//	CUDA Parameters optimized
    printf("Inserisci il numero di simulazioni Monte Carlo(x131.072): ");
    scanf("%d",&SIMS);
    SIMS *= SIMPB;
    printf("\nScenari di Monte Carlo: %d\n",SIMS);
    
    if(risp == 'b'){
        //    Print Option details
        printMultiOpt(&cva.opt);
        //    Cholevski factorization
        Chol(cva.opt.p, cholRho);
        for(i=0;i<N;i++)
            for(j=0;j<N;j++)
                cva.opt.p[i][j]=cholRho[i][j];
    }else{
        printOption(cva.option);
        bs_price[0] = host_bsCall(cva.option);
        int n = cva.option.t;
        dt = cva.option.t/(float)cva.n;
        for(i=1;i<cva.n+1;i++){
            if((cva.option.t -= dt)<0)
                bs_price[i] = 0;
            else
                bs_price[i] = host_bsCall(cva.option);
        }
        cva.option.t = n;
    }

	// Timer init
    CudaCheck( cudaEventCreate( &d_start ));
    CudaCheck( cudaEventCreate( &d_stop ));
    
    // CPU Monte Carlo
    printf("\nCVA execution on CPU:\n");
    CudaCheck( cudaEventRecord( d_start, 0 ));
    host_cvaEquityOption(&cva, SIMS);
    CudaCheck( cudaEventRecord( d_stop, 0));
    CudaCheck( cudaEventSynchronize( d_stop ));
    CudaCheck( cudaEventElapsedTime( &CPU_timeSpent, d_start, d_stop ));
    CPU_timeSpent /= 1000;
    printf("\nPrezzi Simulati:\n");
    
        printf("|\ti\t\t|\tPrezzi BS\t| Differenza Prezzi\t|\tPrezzi\t\t|\tDefault Prob\t|\n");
        for(i=0;i<cva.n+1;i++){
            difference = abs(cva.ee[i].Expected - bs_price[i]);
            printf("|\t%f\t|\t%f\t|\t%f\t|\t%f\t|\t%f\t|\n",dt*i,bs_price[i],difference,cva.ee[i].Expected,cva.dp[i]);
        }
    
    printf("\nCVA: %f\n\n",cva.cva);
    printf("\nTotal execution time: %f s\n\n", CPU_timeSpent);
    printf("--------------------------------------------------\n");
    // GPU Monte Carlo
    printf("\nCVA execution on GPU:\n");
    CudaCheck( cudaEventRecord( d_start, 0 ));
    dev_cvaEquityOption(&cva, BLOCKS, THREADS, SIMS);
    CudaCheck( cudaEventRecord( d_stop, 0));
    CudaCheck( cudaEventSynchronize( d_stop ));
    CudaCheck( cudaEventElapsedTime( &GPU_timeSpent, d_start, d_stop ));
    GPU_timeSpent /= 1000;

    printf("\nTotal execution time: %f s\n\n", GPU_timeSpent);

    printf("\nPrezzi Simulati:\n");
   	printf("|\ti\t\t|\tPrezzi BS\t| Differenza Prezzi\t|\tPrezzi\t\t|\tDefault Prob\t|\n");
   	for(i=0;i<cva.n+1;i++){
   		difference = abs(cva.ee[i].Expected - bs_price[i]);
   		printf("|\t%f\t|\t%f\t|\t%f\t|\t%f\t|\t%f\t|\n",dt*i,bs_price[i],difference,cva.ee[i].Expected,cva.dp[i]);
   	}
    printf("\nCVA: %f\n\n",cva.cva);
    printf("Speed up: %f\n\n",CPU_timeSpent/GPU_timeSpent);
   	free(cva.dp);
   	//free(cva.fp);
   	free(cva.ee);
   	free(bs_price);
    return 0;
}

//Simulation std, rho and covariance matrix
void getRandomSigma( float* std ){
    int i,j=0;
    for(i=0;i<N;i++){
        if(j==0){
            std[i]=0.3;
            j=1;
        }
        else{
            std[i]=0.2;
            j=0;
        }
    }
}
void getRandomRho( float* rho ){
    int i,j;
    //creating the vectors of rhos
    for(i=0;i<N;i++){
        for(j=i;j<N;j++){
            float r;
            if(i==j)
                r=1;
            else
                if(j%2==0)
                    r = 0.5;
                else
                    r= -0.5;
            rho[j+i*N] = r;
            rho[i+j*N] = r;
        }
    }
}
void pushVett( float* vet, float x ){
    int i;
    for(i=0;i<N;i++)
        vet[i] = x;
}
