/*
 *  MonteCarlo.h
 *  Monte Carlo methods in CUDA
 *  Dissertation project
 *  Created on: 06/feb/2018
 *  Author: Marco Matteo Buzzulini
 */

#ifndef MONTECARLO_H_
#define MONTECARLO_H_

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <time.h>

#define N 3

/**
 * This macro checks return value of the CUDA runtime call and exits
 * the application if the call failed.
 */
#ifndef CudaCheck
#define CudaCheck(value) {											\
	cudaError_t _m_cudaStat = value;										\
	if (_m_cudaStat != cudaSuccess) {										\
		fprintf(stderr, "Error %s at line %d in file %s\n",					\
				cudaGetErrorString(_m_cudaStat), __LINE__, __FILE__);		\
		exit(1);															\
	} }
#endif

typedef struct {
    float s;    // stock price
    float k;    // strike price
    float r;    // risk-free rate
    float v;    // the volatility
    float t;    // time to maturity
} OptionData;

// MultiOptionData
typedef struct{
    float s[N];  	//Stock vector
    float v[N];  	//Volatility vector
    float p[N][N]; //Correlation matrix
    float d[N];  	//Drift vector
    float w[N];  	//Weight vector
    float k;
    float t;
    float r;
} MultiOptionData;

typedef struct {
    float Expected;   	// the simulated price
    float Confidence;    // confidence intervall
} OptionValue;

typedef struct{
    // Default probabilities
    float defInt, lgd;
    // Option data
    int ns; 
    OptionData option;
    // Num of simulations
    int n;
}CVA;

// Struct for Monte Carlo methods
typedef struct{
	OptionValue callValue;
	MultiOptionData mopt;
    OptionData sopt;
    int numOpt, path;
} MonteCarloData;

#endif /* MONTECARLO_H_ */
