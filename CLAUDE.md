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
lammps, matlab(非 spack 包,需单独装+手写 modulefile), metis, namd 等,
后续可以继续加。(mpich/mvapich2 不再是目标软件,见下方编译器决定。)

## 编译器/MPI 决定(已确认,不再是"待确认")
新 software stack 主流就是 Intel oneAPI 编译器 + Intel MPI
(intel-oneapi-mpi),不像旧集群那样按软件混用 gcc/nvhpc/intel。GPU 相关
软件直接用 nvhpc 系列(编译器+其自带工具链)即可,不单独引入
mvapich/mpich。gcc 只作为极少数编译不过 icx 的软件的 fallback 保留,不是
default provider。

## 待确认的关键信息
- 新 RHEL10 节点的具体 CPU микроarch(还是 Ice Lake,还是更新的?)
- 是否有 GPU 节点、什么型号

## 部署整体流程(11 步,详见对话历史/项目文档)
1. 现状盘点与目标确认
2. 部署最新 Spack(当前最新稳定版 v1.2.2,比之前记的 v1.2.0 新一个 patch 版本)
3. 配置最新 Intel oneAPI 编译器(当前 2026.0.0)作为主流,gcc 仅作为
   fallback 保留,nvhpc 仅用于 GPU 软件
4. 配置 MPI/CUDA(主流是 intel-oneapi-mpi,GPU 软件配 nvhpc 系列 + 匹配的
   CUDA;不再引入 mvapich/mpich。备注:mvapich2 在当前 Spack 里所有版本
   都标了 deprecated,如果以后真的需要额外 MPI 实现,应该用继任的
   mvapich 包而不是 mvapich2)
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
- git commit message 一律用英文(2026-09-04 起)。

## 当前进度
- Windows 笔记本(dellpro16)已确认装有 WSL2 + Ubuntu 发行版。
- WSL2 Ubuntu 内已安装 Claude Code CLI(2.1.261),已登录。
- 工作目录 /project/fchen14/spack-rhel10 已创建,与集群上路径保持一致
  (注意:只是路径名字一致,不是同一份物理存储,数据同步仍需 git/rsync)。
- 已完成步骤 2-6(草稿阶段,path 全部是本地占位符):
  - Spack v1.2.2 已 clone 到 spack/(git-ignored,版本记录在
    SPACK_VERSION.md)。
  - environments/hpc-software/{config,packages,modules,spack}.yaml 已写好
    并纳入 git,分别对应 install_tree 占位路径、编译器+MPI/CUDA 声明、
    module projections、目标软件 environment。
  - 重要:Spack v1.2.x 已经彻底去掉了 compilers.yaml,编译器改成在
    packages.yaml 里以 external package 形式声明(带 deprecation 迁移
    逻辑),所以没有单独的 compilers.yaml 文件。
  - 用 `spack -C environments/hpc-software ...` 和
    `spack env activate environments/hpc-software` 在本机(WSL2)做了
    schema 校验 + 完整 `spack concretize`(全部 14 个目标软件都能
    concretize 成功,没有真的 install)。发现的问题都已经记在对应
    yaml 文件的注释里,包括:mvapich2 全版本 deprecated 改用 mvapich、
    Spack 默认编译器 provider 顺序是 gcc 优先(已在 packages.yaml 里
    覆盖成 Intel oneAPI 优先)、amber 在 Spack 里只有 18/20 两个版本
    (没有旧集群例子里的 22)。
  - modules.yaml 的 projections 已经用真实 concretize 出来的 spec
    验证过命名效果(如 `hdf5/1.14.6/gcc-14-mpich-5.0.1`、
    `namd/2.14/nvhpc-24.1-cuda-12.6-mpich-5.0.1`,这两个例子是简化
    工具链之前测试留下的,现在环境里已经不装 mpich 了),但编译器/MPI
    包名及版本号还是没法 100% 对齐旧集群格式(比如 "intel-oneapi-compilers"
    vs "intel"),这部分留到步骤 5/11 讨论是否要后处理脚本。
  - 之后按用户要求把工具链简化成主流 Intel oneAPI + intel-oneapi-mpi,
    gcc 降级为 fallback(从 default provider 列表里去掉),nvhpc 只留给
    需要 GPU 的软件按 spec 单独 pin `%nvhpc`,不再作为 provider。
    mpich/mvapich 已从 packages.yaml 和 spack.yaml 的目标软件列表里删除。
    重新 concretize 验证过全部 12 个目标软件都默认落在
    `%oneapi@2026.0.0`;发现两个包级例外(非配置问题):amber 完全不声明
    编译器依赖,ambertools 固定用 %gcc 编译 c/cxx、只有 fortran 走
    %oneapi(ifx)。
  - 待确认的关键信息(CPU 微架构/GPU 型号)仍未回答,所以
    compilers/packages.yaml 里的路径、版本号全部是占位符,标了
    TODO(cluster),真机确认后要替换。
