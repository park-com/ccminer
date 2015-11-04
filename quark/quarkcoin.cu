extern "C"
{
#include "sph/sph_blake.h"
#include "sph/sph_bmw.h"
#include "sph/sph_groestl.h"
#include "sph/sph_skein.h"
#include "sph/sph_jh.h"
#include "sph/sph_keccak.h"
}

#include "miner.h"

#include "cuda_helper.h"
#include "cuda_quark.h"

static uint32_t *d_hash[MAX_GPUS];

// Speicher zur Generierung der Noncevektoren für die bedingten Hashes
static uint32_t *d_branch1Nonces[MAX_GPUS];
static uint32_t *d_branch2Nonces[MAX_GPUS];
static uint32_t *d_branch3Nonces[MAX_GPUS];

// Original Quarkhash Funktion aus einem miner Quelltext
extern "C" void quarkhash(void *state, const void *input)
{
	unsigned char _ALIGN(128) hash[64];

	sph_blake512_context ctx_blake;
	sph_bmw512_context ctx_bmw;
	sph_groestl512_context ctx_groestl;
	sph_jh512_context ctx_jh;
	sph_keccak512_context ctx_keccak;
	sph_skein512_context ctx_skein;

	sph_blake512_init(&ctx_blake);
	sph_blake512 (&ctx_blake, input, 80);
	sph_blake512_close(&ctx_blake, (void*) hash);

	sph_bmw512_init(&ctx_bmw);
	sph_bmw512 (&ctx_bmw, (const void*) hash, 64);
	sph_bmw512_close(&ctx_bmw, (void*) hash);

	if (hash[0] & 0x8)
	{
		sph_groestl512_init(&ctx_groestl);
		sph_groestl512 (&ctx_groestl, (const void*) hash, 64);
		sph_groestl512_close(&ctx_groestl, (void*) hash);
	}
	else
	{
		sph_skein512_init(&ctx_skein);
		sph_skein512 (&ctx_skein, (const void*) hash, 64);
		sph_skein512_close(&ctx_skein, (void*) hash);
	}

	sph_groestl512_init(&ctx_groestl);
	sph_groestl512 (&ctx_groestl, (const void*) hash, 64);
	sph_groestl512_close(&ctx_groestl, (void*) hash);

	sph_jh512_init(&ctx_jh);
	sph_jh512 (&ctx_jh, (const void*) hash, 64);
	sph_jh512_close(&ctx_jh, (void*) hash);

	if (hash[0] & 0x8)
	{
		sph_blake512_init(&ctx_blake);
		sph_blake512 (&ctx_blake, (const void*) hash, 64);
		sph_blake512_close(&ctx_blake, (void*) hash);
	}
	else
	{
		sph_bmw512_init(&ctx_bmw);
		sph_bmw512 (&ctx_bmw, (const void*) hash, 64);
		sph_bmw512_close(&ctx_bmw, (void*) hash);
	}

	sph_keccak512_init(&ctx_keccak);
	sph_keccak512 (&ctx_keccak, (const void*) hash, 64);
	sph_keccak512_close(&ctx_keccak, (void*) hash);

	sph_skein512_init(&ctx_skein);
	sph_skein512 (&ctx_skein, (const void*) hash, 64);
	sph_skein512_close(&ctx_skein, (void*) hash);

	if (hash[0] & 0x8)
	{
		sph_keccak512_init(&ctx_keccak);
		sph_keccak512 (&ctx_keccak, (const void*) hash, 64);
		sph_keccak512_close(&ctx_keccak, (void*) hash);
	}
	else
	{
		sph_jh512_init(&ctx_jh);
		sph_jh512 (&ctx_jh, (const void*) hash, 64);
		sph_jh512_close(&ctx_jh, (void*) hash);
	}

	memcpy(state, hash, 32);
}

#ifdef _DEBUG
#define TRACE(algo) { \
	if (max_nonce == 1 && pdata[19] <= 1) { \
		uint32_t* debugbuf = NULL; \
		cudaMallocHost(&debugbuf, 8*sizeof(uint32_t)); \
		cudaMemcpy(debugbuf, d_hash[thr_id], 8*sizeof(uint32_t), cudaMemcpyDeviceToHost); \
		printf("quark %s %08x %08x %08x %08x...\n", algo, swab32(debugbuf[0]), swab32(debugbuf[1]), \
			swab32(debugbuf[2]), swab32(debugbuf[3])); \
		cudaFreeHost(debugbuf); \
	} \
}
#else
#define TRACE(algo) {}
#endif

static bool init[MAX_GPUS] = { 0 };

extern "C" int scanhash_quark(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done)
{
	uint32_t _ALIGN(64) endiandata[20];
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t first_nonce = pdata[19];
	int dev_id = device_map[thr_id];

	uint32_t throughput =  cuda_default_throughput(thr_id, 1U << 20); // 256*4096
	if (init[thr_id]) throughput = min(throughput, max_nonce - first_nonce);

	if (opt_benchmark)
		ptarget[7] = 0x00F;

	if (!init[thr_id])
	{
		cudaSetDevice(device_map[thr_id]);

		cudaGetLastError();
		CUDA_SAFE_CALL(cudaMalloc(&d_hash[thr_id], (size_t) 64 * throughput));

		quark_blake512_cpu_init(thr_id, throughput);
		quark_groestl512_cpu_init(thr_id, throughput);
		quark_skein512_cpu_init(thr_id, throughput);
		quark_bmw512_cpu_init(thr_id, throughput);
		quark_keccak512_cpu_init(thr_id, throughput);
		quark_jh512_cpu_init(thr_id, throughput);
		cuda_check_cpu_init(thr_id, throughput);
		quark_compactTest_cpu_init(thr_id, throughput);

		cudaMalloc(&d_branch1Nonces[thr_id], sizeof(uint32_t)*throughput);
		cudaMalloc(&d_branch2Nonces[thr_id], sizeof(uint32_t)*throughput);
		cudaMalloc(&d_branch3Nonces[thr_id], sizeof(uint32_t)*throughput);
		CUDA_SAFE_CALL(cudaGetLastError());

		if (device_sm[dev_id] < 300 || cuda_arch[dev_id] < 300) {
			gpulog(LOG_ERR, thr_id, "Device SM 3.0 or more recent required!");
			proper_exit(1);
			return -1;
		}

		init[thr_id] = true;
	}

	for (int k=0; k < 20; k++)
		be32enc(&endiandata[k], pdata[k]);

	quark_blake512_cpu_setBlock_80(thr_id, endiandata);
	cuda_check_cpu_setTarget(ptarget);

	do {
		int order = 0;
		uint32_t nrm1=0, nrm2=0, nrm3=0;

		quark_blake512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]); order++;
		TRACE("blake  :");

		// das ist der unbedingte Branch für BMW512
		quark_bmw512_cpu_hash_64(thr_id, throughput, pdata[19], NULL, d_hash[thr_id], order++);

		quark_compactTest_single_false_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id], NULL,
				d_branch3Nonces[thr_id], &nrm3,
				order++);

		// nur den Skein Branch weiterverfolgen
		quark_skein512_cpu_hash_64(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);

		// das ist der unbedingte Branch für Groestl512
		quark_groestl512_cpu_hash_64(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);

		// das ist der unbedingte Branch für JH512
		quark_jh512_cpu_hash_64(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);

		// quarkNonces in branch1 und branch2 aufsplitten gemäss if (hash[0] & 0x8)
		quark_compactTest_cpu_hash_64(thr_id, nrm3, pdata[19], d_hash[thr_id], d_branch3Nonces[thr_id],
			d_branch1Nonces[thr_id], &nrm1,
			d_branch2Nonces[thr_id], &nrm2,
			order++);

		// das ist der bedingte Branch für Blake512
		quark_blake512_cpu_hash_64(thr_id, nrm1, pdata[19], d_branch1Nonces[thr_id], d_hash[thr_id], order++);

		// das ist der bedingte Branch für Bmw512
		quark_bmw512_cpu_hash_64(thr_id, nrm2, pdata[19], d_branch2Nonces[thr_id], d_hash[thr_id], order++);

		// das ist der unbedingte Branch für Keccak512
		quark_keccak512_cpu_hash_64(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);

		// das ist der unbedingte Branch für Skein512
		quark_skein512_cpu_hash_64(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);

		// quarkNonces in branch1 und branch2 aufsplitten gemäss if (hash[0] & 0x8)
		quark_compactTest_cpu_hash_64(thr_id, nrm3, pdata[19], d_hash[thr_id], d_branch3Nonces[thr_id],
			d_branch1Nonces[thr_id], &nrm1,
			d_branch2Nonces[thr_id], &nrm2,
			order++);

		quark_keccak512_cpu_hash_64(thr_id, nrm1, pdata[19], d_branch1Nonces[thr_id], d_hash[thr_id], order++);
		quark_jh512_cpu_hash_64(thr_id, nrm2, pdata[19], d_branch2Nonces[thr_id], d_hash[thr_id], order++);

		*hashes_done = pdata[19] - first_nonce + 1;

		uint32_t foundNonce = cuda_check_hash_branch(thr_id, nrm3, pdata[19], d_branch3Nonces[thr_id], d_hash[thr_id], order++);
		if  (foundNonce != UINT32_MAX)
		{
			uint32_t vhash[8];
			be32enc(&endiandata[19], foundNonce);
			quarkhash(vhash, endiandata);

			if (vhash[7] <= ptarget[7] && fulltest(vhash, ptarget)) {
				work_set_target_ratio(work, vhash);
				pdata[19] = foundNonce;
				return 1;
			} else {
				gpulog(LOG_WARNING, thr_id, "result for %08x does not validate on CPU!", foundNonce);
				applog_hash((uchar*) vhash);
				applog_hash((uchar*) ptarget);
			}
		}

		pdata[19] += throughput;

	} while (pdata[19] < max_nonce && !work_restart[thr_id].restart);

	*hashes_done = pdata[19] - first_nonce + 1;
	return 0;
}

// cleanup
extern "C" void free_quark(int thr_id)
{
	if (!init[thr_id])
		return;

	cudaThreadSynchronize();

	cudaFree(d_hash[thr_id]);

	cudaFree(d_branch1Nonces[thr_id]);
	cudaFree(d_branch2Nonces[thr_id]);
	cudaFree(d_branch3Nonces[thr_id]);

	quark_blake512_cpu_free(thr_id);
	quark_groestl512_cpu_free(thr_id);
	quark_compactTest_cpu_free(thr_id);

	cuda_check_cpu_free(thr_id);
	init[thr_id] = false;

	cudaDeviceSynchronize();
}
