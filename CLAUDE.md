# RHEL10 Spack 部署项目

## 目标
在新的 RHEL10 集群上部署最新版 Spack,编译一批 HPC 软件,并让生成的 module key
格式与现有集群(linux-rhel8-icelake)保持一致。软件版本不必照抄旧版本,尽量用最新的;
编译器优先用最新的 Intel oneAPI。

## 现有集群 module 命名格式(需要在新集群上延续)
`<软件>/<版本>/<编译器>-<编译器版本>[-cuda-<版本>][-<mpi>-<mpi版本>]`
例如:
amber/22/intel-2021.5.1-cuda-11.5.2-intel-mpi-2021.5.1
cp2k/7.1/gcc-8.5.0-openmpi-4.0.1
bwa/0.7.17/nvhpc-24.1

## 目标软件列表(版本用最新的,不锁旧版本)
amber, ambertools, boost, bowtie2, bwa, cmake, conda/mamba, cosma, cp2k,
lammps, matlab(非 spack 包,需单独装+手写 modulefile), metis, mpich,
mvapich2, namd 等,后续可以继续加。

## 待确认的关键信息
- 新 RHEL10 节点的具体 CPU микроarch(还是 Ice Lake,还是更新的?)
- 是否有 GPU 节点、什么型号
- 是否所有软件统一切到 Intel oneAPI 编译器,还是像现在一样按软件混用
  gcc/nvhpc/intel(cp2k 用 gcc+openmpi,bwa 用 nvhpc 等)

## 部署整体流程(11 步,详见对话历史/项目文档)
1. 现状盘点与目标确认
2. 部署最新 Spack(当前最新稳定版 v1.2.0)
3. 配置最新 Intel oneAPI 编译器(当前 2026.0.0)+ 按需保留 gcc/nvhpc
4. 配置 MPI/CUDA(intel-oneapi-mpi, mvapich2, mpich, 匹配 GPU 的 CUDA)
5. 设计 module 命名规则(modules.yaml projections,可能需要后处理脚本
   来精确匹配上面的命名格式)
6. 用 spack.yaml environment 组织软件列表
7. concretize + 批量编译
8. 生成并校验 module 文件
9. 功能/性能验证(test suite / benchmark,GPU 路径验证)
10. 灰度上线,与旧 module 并存,收集反馈后再切换
11. 建立可重复的维护/升级机制,配置全部纳入 git 版本控制

## 工作方式(重要约束)
- 出于安全原因,集群上不能直接跑 Claude。
- 本地(WSL2 Ubuntu on dellpro16)用 Claude Code 做:配置文件编写、
  spack concretize/spec 这类不需要匹配目标硬件的验证、脚本开发。
- 真正的 `spack install` 编译必须在集群的 compute node 上跑(sbatch/qsub
  提交,不要在 login node 上跑),因为涉及目标 CPU 优化、InfiniBand/MPI
  底层库、license 软件(Matlab)、真实文件系统路径。
- 所有配置纳入 git repo 管理,而不是零散文件靠 rsync 覆盖。集群侧如果能
  访问 git 远端就直接 git pull;如果 air-gapped,就传 git bundle 过去再
  git pull,保留版本历史。
- 集群上跑出来的编译报错日志,人工抄回本地/贴给 Claude 辅助调试。

## 当前进度
- Windows 笔记本(dellpro16)已确认装有 WSL2 + Ubuntu 发行版。
- WSL2 Ubuntu 内已安装 Claude Code CLI(2.1.261),已登录。
- 工作目录 /project/fchen14/spack-rhel10 已创建,与集群上路径保持一致
  (注意:只是路径名字一致,不是同一份物理存储,数据同步仍需 git/rsync)。
