#include "hySortOD_lib.h"

using namespace std;

int main(int argc, char **argv) {
    // Process command-line arguments
    int N;
    int DIM;
    int BIN;
    int MINSPLIT;
    int NORMALIZE =
            1; // Set to 1 to normalize datasets - Does not affect timeTrails
    char inputFname[500] = ""; // Dataset
    int APPROACH = 1;          // 0 for Naive strategy and 1 for Tree strategy
    int TREE_SELECT =
            3; // Optional parameter (default -3) 1 for simple tree, 2 for tree with
    // optimized locality, 3 for tree with optimized locality and
    // traversal, Use 0 for naive strategy

    if (argc != 9) {
        fprintf(stderr,
                "Please provide the following on the command line: N (number of "
                "lines in the file), dimensionality (number of coordinates per "
                "point/feature vector), BIN (Bin parameter), Min Split(Threshold), "
                "Normalize (0 or 1), dataset filename. ");
        return 0;
    }

    // Read CL arguments
    sscanf(argv[1], "%d", &N);
    sscanf(argv[2], "%d", &DIM);
    sscanf(argv[3], "%d", &BIN);
    sscanf(argv[4], "%d", &MINSPLIT);
    sscanf(argv[5], "%d", &NORMALIZE);
    strcpy(inputFname, argv[6]);
    sscanf(argv[7], "%d", &APPROACH);
    sscanf(argv[8], "%d", &TREE_SELECT);

    if (N < 1 || DIM < 1 || BIN < 1 || MINSPLIT < 0 || NORMALIZE > 1 ||
        NORMALIZE < 0 || APPROACH < 0 || APPROACH > 1 || TREE_SELECT < 0 ||
        TREE_SELECT > 3) {
        cout << "\nOne of the following are invalid: N, DIM, BIN , NORMALIZE, "
                "APPROACH, TREE_SELECT "
             << endl;
        return 0;
    } else {

        string currentTreeSelect = "NONE";

        if (APPROACH == 1) {
            currentTreeSelect = treeSelect[TREE_SELECT - 1];
        }

        cout << "\nNumber of lines (N): " << N << " Dimensionality: " << DIM
             << " BIN Size: " << BIN << " MinSplit: " << MINSPLIT
             << " Normalize: " << NORMALIZE << " Filename: " << inputFname
             << " Approach: " << approach[APPROACH]
             << " Selected tree: " << currentTreeSelect << endl;
    }

    // allocate memory for dataset
    int totalElements = N * DIM;
    size_t datasetMemory = sizeof(double) * totalElements;
    double *h_dataset = (double *) malloc(datasetMemory);

    // Import dataset
    int ret = importDataset(inputFname, N, h_dataset, DIM);

    if (ret == 1) {
        return 0;
    }

    // Normalize dataset if required
    if (NORMALIZE == 1) {
        normalizeDataset(h_dataset, N, DIM);
    }

    // Record total time execution time
    cudaEvent_t totalTimeStart, totalTimeStop;
    cudaEventCreate(&totalTimeStart);
    cudaEventCreate(&totalTimeStop);
    cudaEventRecord(totalTimeStart);

    // Reorder dimensions in the dataset by variance
    // h_dataset = reorderByDimensions(h_dataset, N, DIM);

    // Supporting variables
    float totalTime = 0;
    int *d_hypercube = nullptr;
    double *d_dataset = nullptr;
    int blockDim = 256;

    cudaEvent_t buildHypercubeArrayStart, buildHypercubeArrayStop;
    size_t hypercubeMemory = (sizeof(int) * totalElements);

    // Set threads per block
    dim3
    dimGrid(ceil((float) N / (float) blockDim), 1, 1);
    dim3 dimBlock(blockDim, 1, 1);

    // Record hypercube array time
    cudaEventCreate(&buildHypercubeArrayStart);
    cudaEventCreate(&buildHypercubeArrayStop);
    cudaEventRecord(buildHypercubeArrayStart);

    // Allocate memory for hypercube array
    int *h_hypercube = (int *) calloc(totalElements, sizeof(int));

    // Allocate memory for dataset in device
    cudaMalloc((void **) &d_dataset, datasetMemory);

    cudaMemcpy(d_dataset, h_dataset, datasetMemory, cudaMemcpyHostToDevice);

    // Allocate memory for hypercube array
    cudaMalloc((void **) &d_hypercube, hypercubeMemory);

    cudaMemcpy(d_hypercube, h_hypercube, hypercubeMemory, cudaMemcpyHostToDevice);

    // Build hypercube array
    buildNonEncodedHypercubeArray<<<dimGrid, dimBlock>>>(d_hypercube, d_dataset,
                                                         N, BIN, DIM);

    // Copy memory from device to host
    cudaMemcpy(h_hypercube, d_hypercube, (hypercubeMemory),
               cudaMemcpyDeviceToHost);

    // Free memory
    cudaFree(d_dataset);
    cudaFree(d_hypercube);

    // Use map to remove duplicates and count instances
    map <vector<int>, vector<int>> h_hypercube_mapper;

    for (int i = 0; i + DIM <= N * DIM; i = i + DIM) {

        vector<int> h_hypercube_key(h_hypercube + i, h_hypercube + i + DIM);

        // If current hypercube is not present, then update map
        if (h_hypercube_mapper.find(h_hypercube_key) == h_hypercube_mapper.end()) {
            vector<int> h_hypercube_instance;
            // Append new key value pair
            h_hypercube_mapper[h_hypercube_key] = h_hypercube_instance;
        }

        // Update instances
        h_hypercube_mapper[h_hypercube_key].push_back(i / DIM);
    }

    // Supporting variables
    map < vector < int > , vector < int >> ::iterator
    itr;
    int *h_instancesCount = nullptr;
    int hypercubePos = 0;
    int distinctHypercubeCount = h_hypercube_mapper.size();
    float buildHypercubeArrayTime = 0;
    float neighborhoodDensityTime;
    int *d_hypercubeArray;
    int maxNeighborhoodDensity = INT_MIN;
    totalElements = distinctHypercubeCount * DIM;

    size_t hypercubeArraySize = sizeof(int) * totalElements;

    // Allocate memory for distinct hypercube array
    int *h_hypercubeArray = (int *) malloc(hypercubeArraySize);

    // Allocate memory for instances count
    h_instancesCount = (int *) malloc(sizeof(int) * distinctHypercubeCount);

    // Copy map key (hypercube) into a linear array
    for (itr = h_hypercube_mapper.begin(); itr != h_hypercube_mapper.end();
         itr++) {
        memcpy(h_hypercubeArray + hypercubePos, itr->first.data(),
               sizeof(int) * itr->first.size());
        h_instancesCount[hypercubePos / itr->first.size()] = itr->second.size();
        hypercubePos += itr->first.size();
    }

    // Allocate memory for distinct hypercube array in device
    cudaMalloc((void **) &d_hypercubeArray, hypercubeArraySize);

    cudaMemcpy(d_hypercubeArray, h_hypercubeArray, hypercubeArraySize,
               cudaMemcpyHostToDevice);

    cudaDeviceSynchronize();
    cudaEventRecord(buildHypercubeArrayStop);
    cudaEventSynchronize(buildHypercubeArrayStop);

    cudaEventElapsedTime(&buildHypercubeArrayTime, buildHypercubeArrayStart,
                         buildHypercubeArrayStop);

    // Allocate memory for neighborhood density
    int *h_neighborhoodDensity =
            (int *) calloc(distinctHypercubeCount, sizeof(int));

    // Naive approach
    if (APPROACH == 0) {

        neighborhoodDensityTime =
                naiveStrategy(d_hypercubeArray, h_neighborhoodDensity, h_instancesCount,
                              distinctHypercubeCount, BIN, DIM);

    } else {
        // Simple tree
        if (TREE_SELECT == 1) {
            neighborhoodDensityTime = simpleTreeStrategy(
                    h_hypercubeArray, d_hypercubeArray, h_neighborhoodDensity,
                    h_instancesCount, distinctHypercubeCount, DIM, MINSPLIT);

        }
            // Locality optimized tree
        else if (TREE_SELECT == 2) {
            neighborhoodDensityTime = localityOptimTreeStrategy(
                    h_hypercubeArray, d_hypercubeArray, h_neighborhoodDensity,
                    h_instancesCount, distinctHypercubeCount, DIM, MINSPLIT);

        }
            // Locality and traversal optimized tree
        else {
            neighborhoodDensityTime = finalOptimTreeStrategy(
                    h_hypercubeArray, d_hypercubeArray, h_neighborhoodDensity,
                    h_instancesCount, distinctHypercubeCount, DIM, MINSPLIT);
        }
    }

    // Find max neighborhood density
    for (int i = 0; i < distinctHypercubeCount; i++) {
        if (h_neighborhoodDensity[i] > maxNeighborhoodDensity) {
            maxNeighborhoodDensity = h_neighborhoodDensity[i];
        }
    }

    // Calculate Outlier Score
    float *h_outlierScore = (float *) malloc(sizeof(float) * N);

    calculateOutlierScore(h_outlierScore, h_neighborhoodDensity,
                          h_hypercube_mapper, N, maxNeighborhoodDensity);
    clock_t end = clock();

    cudaDeviceSynchronize();
    cudaEventRecord(totalTimeStop);
    cudaEventSynchronize(totalTimeStop);

    cudaEventElapsedTime(&totalTime, totalTimeStart, totalTimeStop);

    printf("============TIME RESULTS================\n");

    printf("Total threads: %d\n", omp_get_max_threads());

    printf("Total time for execution is %f sec \n", (totalTime / 1000));

    printf("Total time for building hypercube is %f sec \n",
           (buildHypercubeArrayTime / 1000));

    printf("Time for neighborhood density is %f sec \n",
           (neighborhoodDensityTime / (1000)));

    cudaError_t error = cudaGetLastError();

    if (error != cudaSuccess) {
        printf("%s \n", cudaGetErrorString(error));
    }

    // free dataset
    free(h_dataset);

    return 0;
}
