# Context ceiling on RTX 5060 8 GB (7704 MiB usable)

Captured by scripts/02-context-sweep.sh. Two separate runs: one with MTP,
one without. Each entry is a server load attempt -- 'LOADED' means it came
up and served; 'FAILED' shows the cudaMalloc error.

## with MTP (--spec-type draft-mtp --spec-draft-n-max 1)
```
  -c 32768  LOADED   VRAM: 7284 MiB, 422 MiB
  -c 40960  LOADED   VRAM: 7508 MiB, 198 MiB
  -c 49152  FAILED   allocating 146.02 MiB on device 0: cudaMalloc failed: out of memory
  -c 57344  FAILED   allocating 224.00 MiB on device 0: cudaMalloc failed: out of memory
SWEEP_DONE
```

## without MTP
```
  no-MTP -c 65536   LOADED   VRAM: 7268 MiB, 438 MiB
  no-MTP -c 98304   FAILED   allocating 570.28 MiB on device 0: cudaMalloc failed: out of memory
  no-MTP -c 131072  FAILED   allocating 2304.00 MiB on device 0: cudaMalloc failed: out of memory
NOMTP_DONE

  no-MTP -c 73728   LOADED   VRAM: 7452 MiB, 254 MiB
  no-MTP -c 81920   LOADED   VRAM: 7636 MiB, 70 MiB
  no-MTP -c 90112   FAILED   allocating 530.28 MiB on device 0: cudaMalloc failed: out of memory
DONE2
```

## reading

- **40,960 with MTP** is the golden config (7,508 MiB, 198 free)
- dropping MTP doubles the ceiling to 81,920 -- but produces garbage
  output; see no-mtp-collapse.md
- the failure is always the compute buffer, never the KV cache:
  ```
  ggml_backend_cuda_buffer_type_alloc_buffer: allocating NNN.NN MiB on device 0: cudaMalloc failed: out of memory
  graph_reserve: failed to allocate compute buffers
  ```
