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

**GPU 软件(cp2k/lammps/namd)均已 `+cuda cuda_arch=80` 真实编译验证通过**
(2026-09-15/16),详见下面"GPU(+cuda)软件真实编译验证与 CUDA 版本分流"
章节——过程中挖出一长串 CUDA 13.3 相关的真实上游/配置兼容性 bug,namd
最终还专门配了第二份 CUDA(12.9.0)。

**Tier 1/2/3 批次(已加入 `config/specs.yaml`,详见下面"当前进度"章节
末尾)**:
- Tier 1:eigen, git, gsl, hwloc, valgrind(加已在清单里的 boost/
  cmake)——都只需要普通编译器,不涉及 MPI/CUDA。
- Tier 2:fftw, hdf5, netcdf-c, netcdf-cxx4, netcdf-fortran,
  parallel-netcdf, parmetis, superlu-dist, hypre, petsc(加已在清单
  里的 metis)——依赖 intel-oneapi-mpi。
- Tier 3:bowtie2, hisat2, star, spades(`~sra ~tools`), vcftools,
  revbayes——生信工具。

三批都各自用独立的 `environments/tierN-test` + `scripts/
tierN-test-install.sh` 在个人账号目录下做过真实批量编译验证(install_tree
互相独立,不复用),**Tier 1/2/3 均已真实编译全部通过**,详见下面
"当前进度"章节末尾的过程记录(尤其是 Tier 3 的 spades 遇到的一系列坑)。
还没挪到 production。

## 编译器/MPI 决定(已确认,不再是"待确认")
新 software stack 主流就是 Intel oneAPI 编译器 + Intel MPI
(intel-oneapi-mpi),不像旧集群那样按软件混用 gcc/nvhpc/intel。GPU 相关
软件直接用 nvhpc 系列(编译器+其自带工具链)即可,不单独引入
mvapich/mpich。gcc 只作为极少数编译不过 icx 的软件的 fallback 保留,不是
default provider。

## 硬件信息(已确认,不再是"待确认")
- CPU target:icelake(`packages:all:target: [icelake]`)。
- GPU:Ampere 级(如 A100),`cuda_arch=80`,作为
  `packages:all:variants` 的默认值,GPU 软件(namd、lammps 等)在
  spack.yaml 里再显式加 `+cuda cuda_arch=80 %nvhpc`。
- CUDA 版本:默认 pin 到 13.3.0,匹配 GPU 驱动支持的 CUDA 版本。**最终
  决定(中间反复过,现在拍板):跟 intel-oneapi-compilers/intel-oneapi-mpi/
  nvhpc 一样是 external**,指向集群上真实的手动安装路径
  `/usr/local/packages/cuda/13.3`,不是 Spack 自装。中间一度改成
  Spack 自装过(`packages:cuda:require: "@13.3.0"`),但后来连同其余
  三个一起又改回了 external——完整过程和原因见下面"编译器/MPI/CUDA
  external 路径:最终决定"章节。
  **2026-09-16 追加:又注册了第二份、并行的 `cuda@12.9.0` external**
  (`/usr/local/packages/cuda/12.9`,独立 --toolkit 安装,不装驱动),
  专门给 namd 用——原因和完整过程见下面"GPU(+cuda)软件真实编译验证与
  CUDA 版本分流"章节。cp2k/lammps 仍然用默认的 13.3.0,两份 CUDA 互不
  影响(`unify: false` 保证不同 root spec 能各自选不同版本)。
- 已知问题(测出来的,不是猜的,`spack info amber` 验证过):Spack 的
  `amber` 包(仅 18/20 两个版本)在 `+cuda cuda_arch=80` 时实际支持的
  CUDA 范围是 `cuda@11.0:11.1`——不只是"上限 11.1",而是两条
  `depends_on` 同时生效取交集的结果:`cuda@:11.1 when @20:+cuda`(通用
  上限)交上 `cuda@11.0: when cuda_arch=80`(cuda_arch=80 专属下限)。
  跟我们 confirmed 的 cuda@13.3.0 完全不兼容,`cuda:require: "@13.3.0"`
  又把版本锁死了,不允许两者并存。目前 amber 先按纯 CPU(`~cuda`)处理,
  GPU 版 amber 需要以后另外决定(换新的 package.py/patch,或者专门为
  amber 再注册一个 cuda@11.0/11.1 的额外 external,牺牲"只有一份 CUDA"
  的简洁性)。
- 本地 WSL2 (dellpro16) 自己识别成 `skylake`,不是 icelake,所以要在
  spack.yaml 里加 `concretizer:targets:host_compatible: false` 才能让
  `packages:all:target: [icelake]` 真正生效,不然本地 concretize 会默默
  用 skylake——这条本地专用,真机上跑在 icelake 节点时无影响。

## 编译器/MPI/CUDA external 路径:最终决定

**当前状态(已拍板):intel-oneapi-compilers、intel-oneapi-mpi、nvhpc、
cuda 四个全部是 external + `buildable: false`**,指向集群上真实的手动
安装路径(不是占位符了,已用真实路径替换):

```yaml
packages:
  intel-oneapi-compilers:
    externals:
    - spec: intel-oneapi-compilers@2026.1.0 languages:='c,c++,fortran'
      prefix: /usr/local/packages/compilers/intel-oneapi-2026
      extra_attributes:
        compilers:
          c: /usr/local/packages/compilers/intel-oneapi-2026/compiler/2026.1/bin/icx
          cxx: /usr/local/packages/compilers/intel-oneapi-2026/compiler/2026.1/bin/icpx
          fortran: /usr/local/packages/compilers/intel-oneapi-2026/compiler/2026.1/bin/ifx
    buildable: false
  intel-oneapi-mpi:
    externals:
    - spec: intel-oneapi-mpi@2021.18.0
      prefix: /usr/local/packages/compilers/intel-oneapi-2026
    buildable: false
  nvhpc:
    externals:
    - spec: nvhpc@26.5 languages:='c,c++,fortran'
      prefix: /usr/local/packages/compilers/nvhpc/Linux_x86_64/26.5
      extra_attributes:
        compilers:
          c: /usr/local/packages/compilers/nvhpc/Linux_x86_64/26.5/compilers/bin/nvc
          cxx: /usr/local/packages/compilers/nvhpc/Linux_x86_64/26.5/compilers/bin/nvc++
          fortran: /usr/local/packages/compilers/nvhpc/Linux_x86_64/26.5/compilers/bin/nvfortran
    buildable: false
  cuda:
    externals:
    - spec: cuda@13.3.0
      prefix: /usr/local/packages/cuda/13.3
    buildable: false
```

要点:
- **`extra_attributes.compilers`(c/cxx/fortran 真实可执行文件路径)对
  intel-oneapi-compilers 和 nvhpc 是必须的**——Spack v1.2 的新编译器
  模型下,只声明 `prefix:` 不够,集群上真实编译报过
  `exec: None: not found` / `C compiler cannot create executables`,
  加上这个字段才能让 Spack 找到真实的 icx/icpx/ifx、nvc/nvc++/nvfortran
  可执行文件。intel-oneapi-mpi 和 cuda 不是编译器,不需要这个字段。
- **spec 字符串里的 `languages:='c,c++,fortran'`**(intel-oneapi-compilers
  和 nvhpc 两个)参考了 Spack 自己探测 gcc 时(`~/.spack/packages.yaml`)
  的写法,显式声明这个 external 包提供哪些语言。
- **intel-oneapi-mkl 也已注册为 external**,并设为默认 BLAS/LAPACK
  provider(`packages:all:providers:{blas,lapack}: [intel-oneapi-mkl]`),
  跟 intel-oneapi-compilers 共享同一个 prefix——修复了 cosma 编译期间的
  "Invalid Host BLAS backend" 报错(cosma 需要一个真正的 BLAS/LAPACK
  provider,不只是编译器)。
- gcc(RHEL10 系统自带)仍然是唯一的非 external(`buildable: true`)
  例外,继续只当 fallback,不是 default provider。

### 这个决定是怎么来的(完整过程,供以后回顾)

用户最初要求把 intel-oneapi-compilers、intel-oneapi-mpi、nvhpc、cuda
四个"基础组件"全部改成 Spack 自装(不用 external),理由是"即使系统
安装验证可用也不用 external,统一由 Spack 管理,可复现"。实测下来:

- **cuda 单独自装:完全没问题。** cuda 不提供 c/cxx/fortran 这几个
  "编译器虚包"(它不是编译器),所以不会碰到下面这两个坑。**中间一度
  采用过**(`packages:cuda:require: "@13.3.0"`,不再 external)。
- **intel-oneapi-compilers/intel-oneapi-mpi/nvhpc 也一起自装:实测遇到
  两个真实的 Spack concretizer 限制**:
  1. **不能批量装。** 同一条 `spack install a b c` 命令里,如果 a/b/c
     互相之间有一个要被"当场新建"却又被另一个当编译器用,Spack 的
     concretizer 会直接拒绝求解,报错
     "Only external, or concrete, compilers are allowed for the {c/cxx}
     language"(直接来自 Spack 源码
     `spack/lib/spack/spack/solver/concretize.lp:1930`)。必须一个一个
     单独 `spack install`,让前一个先真正装完、变成"concrete",后一个才能
     把它当编译器复用。
  2. **就算一个一个装,"reuse" 逻辑还是会不听 `packages:all:providers`
     的偏好顺序。** 实测:一旦 nvhpc 真的被装出来(不再是 external),
     Spack 会开始把 nvhpc 复用成一堆无关小软件包(bzip2、gdbm、
     coreutils、甚至 intel-oneapi-mpi 自己)的编译器,完全无视我们配置的
     `c: [intel-oneapi-compilers, gcc]`(nvhpc 根本不在这个列表里)。
     更极端的一次:intel-oneapi-compilers 装好之后,一个完全没有任何
     约束的 `cuda` spec 反而直接 concretize 失败,即使 gcc 仍然是
     external、理论上应该能兜底。试过
     `concretizer:duplicates:strategy:full`、强制 `%gcc` 都没解决。
  拿这两个实测结果去问用户后,**第一轮决定是"只有 cuda 自装,其余三个
  external"**。

  后来用户又提出了一个"两阶段安装"方案想绕开限制 1(阶段一单独一条
  命令 `spack install intel-oneapi-compilers intel-oneapi-mpi nvhpc
  cuda`,阶段二再装其余环境)。实测发现:
  - 阶段一在真正隔离的情况下(用 `spack -C config -C <env-dir> install`
    配置作用域方式,而不是 `spack env activate` ——后者哪怕只给
    `install` 传具体包名,也总会把整个 environment 的其余 root 一起拉进
    同一次 concretize,起不到隔离作用)确实是干净的,没有触发限制 2 的
    reuse 渗透。
  - 但阶段二(工具链装完之后再 concretize 环境剩余部分)**渗透问题仍然
    存在**:cmake 被渗透成 `%nvhpc` 导致 `+ownlibs` 冲突失败;修了 cmake
    的 `require: one_of: [%intel-oneapi-compilers, %gcc]` 之后,同样的
    问题又在 python(被 bowtie2 拉入)上复现——说明这是系统性问题,
    "两阶段"只解决了限制 1,没有解决限制 2,继续下去大概率要给每个被
    渗透的包逐个打补丁。

  **最终决定(推翻了"只有 cuda 自装"那一轮,也放弃了"两阶段自装"这个
  方向):四个全部改回 external**,理由是这样上面两个限制都不会发生
  (external + `buildable: false` 的包永远不会被"当场新建",自然不会
  触发限制 1 和限制 2)——比继续跟 reuse 渗透打地鼠简单可靠。之前给
  cmake 加的那条 `require: one_of: [...]` workaround、以及"两阶段安装"
  相关的文档/脚本痕迹,都已经在改回 external 的同时清理掉了。

## Environment 目录结构(dev-local / production 拆分,已确认)
不再是单一的 `environments/hpc-software/`,现在拆成两份 environment,
GPU 节点和 CPU-only 节点不单独拆 profile(除了有没有 GPU,其余完全
一样):

```
config/                    # 共享配置,dev-local/production 都通过
  packages.yaml            # include: 引用,不复制两份
  modules.yaml              # (modules.yaml 只放 projections/core_compilers
                            #  等命名相关的部分,不含 roots)
environments/
  dev-local/
    spack.yaml              # include ../../config/{packages,modules}.yaml
                            # + 本地专用的 config:/modules:roots/specs
  production/
    spack.yaml              # 同上,但 install_tree/module roots 换成
                            # 集群占位路径
```

- 共享部分(一份文件,两边 `include:` 引用,不复制):编译器/MPI/CUDA
  声明、`packages:all:{providers,target,variants}`(包括 icelake/
  cuda_arch=80/cuda@13.3.0)、modules.yaml 里的 `projections`/
  `core_compilers`/`hierarchy` 等命名规则。
- 各自独有、写在各自 spack.yaml 里的内容:
  - `config:install_tree`(以及 source_cache/misc_cache/license_dir 等
    跟着 install_tree 走的路径):
    - dev-local:`/project/fchen14/spack-rhel10/spack-install`(保持不变,
      本地验证用)。
    - production:`/usr/local/packages/spack`(占位,具体名字还没定,
      只需要改这一处)。
  - `modules:default:roots:lmod`(module 文件生成目录):
    - dev-local:`/project/fchen14/spack-rhel10/spack-install/modules`。
    - production:
      `/usr/local/packages/Modules/default/modulefiles/linux-rhel10-icelake`
      (占位,匹配旧集群 modulefiles 命名习惯)。
  - `specs:`(目标软件列表):Spack 的 environment schema 里
    `include:` 能拉的"section"文件不包括 `specs:`(只有
    config/packages/modules/concretizer 等,specs 是 environment
    manifest 自己的字段),所以没法直接 `include:` 共享。已经用
    **config/specs.yaml + scripts/render-specs.py** 解决了手动同步的
    问题,见下面"改软件清单流程"。
  - `concretizer:targets:host_compatible: false`:dev-local 上是必须的
    (本机识别成 skylake),production 上其实用不上(真机就是 icelake),
    但为了两份文件尽量一致还是都保留了,无副作用。

用 dev-local 重新跑过 `spack concretize` + `spack install --fake` +
`spack module lmod refresh` 全套验证过拆分后配置没坏,细节见下面
"当前进度"。

## 改软件清单流程(已确认)
目标软件列表(`specs:`)现在唯一来源是 `config/specs.yaml`,不要直接改
`environments/{dev-local,production}/spack.yaml` 里
`# >>> BEGIN GENERATED SPECS` 到 `# <<< END GENERATED SPECS` 之间的内容
——那段是生成出来的,手改了下次跑脚本会被覆盖。

流程:
1. 编辑 `config/specs.yaml` 里的 `specs:` 列表(加/删软件、改
   variant/编译器 pin,比如 `+cuda cuda_arch=80 %nvhpc`)。
2. 跑 `python3 scripts/render-specs.py`,会把改动同步套进两份
   spack.yaml 的生成区块。
3. `git diff` 确认两份 spack.yaml 的改动跟预期一致。
4. 用 dev-local 跑一遍 `spack concretize`(必要时 `spack install
   --fake` 做 module 生成的 smoke test)确认没有 concretize 失败。
5. 把 `config/specs.yaml` 和两份 spack.yaml 一起 commit。

`scripts/render-specs.py --check` 可以只检查、不写文件——如果有人手改了
生成区块导致跟 `config/specs.yaml` 不一致,会打印 `OUT OF DATE` 并以非零
状态退出,适合接进 CI/pre-commit(目前还没接,先记录这个能力)。

脚本原理:把 `config/specs.yaml` 里从 `specs:` 那一行到文件末尾整段当
纯文本(不解析/重新序列化成 YAML,避免把注释格式搞乱),缩进两格之后
原样塞进两份 spack.yaml 的 BEGIN/END 标记之间。

## 部署整体流程(11 步,详见对话历史/项目文档)
1. 现状盘点与目标确认
2. 部署最新 Spack(当前最新稳定版 v1.2.2,比之前记的 v1.2.0 新一个 patch 版本)
3. 配置最新 Intel oneAPI 编译器(当前 2026.0.0)作为主流,gcc 仅作为
   fallback 保留,nvhpc 仅用于 GPU 软件
4. 配置 MPI/CUDA(主流是 intel-oneapi-mpi、GPU 软件配 nvhpc 系列、CUDA
   13.3.0——四个都是 external + 真实集群路径,见下面"硬件信息"/"编译器
   /MPI/CUDA external 路径:最终决定"章节;不再引入 mvapich/mpich。备注:
   mvapich2 在当前 Spack 里所有版本都标了 deprecated,如果以后真的需要
   额外 MPI 实现,应该用继任的 mvapich 包而不是 mvapich2)
5. 设计 module 命名规则(modules.yaml projections,Lmod 版本已经验证过并
   拍板,详见下面"Step 5"章节;决定保留 intel-oneapi-compilers/
   intel-oneapi-mpi 原生包名,不写重命名后处理脚本)
6. 用 spack.yaml environment 组织软件列表
7. concretize + 批量编译
8. 生成并校验 module 文件
9. 功能/性能验证(test suite / benchmark,GPU 路径验证)
10. 灰度上线,与旧 module 并存,收集反馈后再切换
11. 建立可重复的维护/升级机制,配置全部纳入 git 版本控制

## Step 5: module 命名方案(Lmod)结论

modules.yaml 已经从 Tcl 草稿切到 Lmod(现在是共享的 config/modules.yaml,
见上面"Environment 目录结构"章节),projections 尽量拼目标格式
`<软件>/<版本>/<编译器>-<编译器版本>[-cuda-<版本>][-<mpi>-<mpi版本>]`。
amber 跳过(它在 Spack 里不声明编译器依赖,没法拼)。

**用真实 concretize 出来的 spec 生成过真实 module 路径验证**(不是只做
schema 校验),关键发现:

1. Lmod 和 Tcl 不一样,**projections 只控制"叶子名"**(module load 之后
   打的那串字符串),不控制目录层级。Lmod 的文件布局代码
   (spack/lib/spack/spack/modules/lmod.py)会强制把每个 module 挂到一个
   "compiler" 层级下面:标了 `core_compilers` 的编译器落在 `Core/`,
   目录里直接可见;没标 core 的编译器会落在 `<编译器>/<版本>/` 目录下,
   用户必须先 `module load <编译器>/<版本>` 才能看到这个软件——这跟旧
   集群"不用先 unlock,直接 module load 完整名字"的扁平体验不一样,
   而且这跟 projections 配置完全无关,改 projection 模板也改不了。
   - 解决办法(纯配置,不需要脚本):把我们注册的三个编译器
     (intel-oneapi-compilers, nvhpc, gcc)**全部**标成 `core_compilers`。
     验证结果:所有情况都落到 `Core/` 下,不再需要先 unlock,比如:
     - `Core/cp2k/2026.1/intel-oneapi-compilers-2026.0.0-intel-oneapi-mpi-2026.0.0.lua`
     - `Core/namd/2.14/nvhpc-24.1-cuda-12.6-intel-oneapi-mpi-2026.0.0.lua`(强制
       `+cuda %nvhpc` 测试出来的)
     - `Core/ambertools/25/gcc-14-intel-oneapi-mpi-2026.0.0.lua`(gcc/oneapi
       混合编译的情况)
   - 副作用:Spack 自带的 linux 默认配置本来就有 `hierarchy: [mpi]`,
     普通的 `hierarchy: []` 会被"合并"而不是"替换"掉默认值,要用 Spack 的
     `::` override 语法(`hierarchy:: []`)才能真正清空。

2. 除了上面的目录层级问题,还剩三个 projections 语法本身解决不了的字段
   (跟用什么编译器无关,是 Spack 数据模型本身的限制,和之前 Tcl 草稿
   发现的问题一样):
   - **编译器名字**:`{compiler.name}` 拼出来是 Spack 包名
     "intel-oneapi-compilers",不是旧集群的 "intel"(nvhpc/gcc 这两个
     碰巧本来就对得上)。Spack 确实有一张兼容表
     (spack/lib/spack/spack/aliases.py:
     `intel-oneapi-compilers -> oneapi`),但那张表只在解析老式
     `%oneapi` 这种 spec 字符串时用,不会体现在 Spec.format()/
     projections 里,而且它的别名是 "oneapi" 不是 "intel",对不上旧
     格式——这是实测确认的,不是猜的。
   - **MPI 名字**:同理,`{^mpi.name}` 拼出来是 "intel-oneapi-mpi",不是
     旧格式的 "intel-mpi"。
   - **版本号**:旧集群的 "intel-2021.5.1" 是经典 icc 编译器自己的内部
     版本号,新的是 oneAPI 工具包发布版本号(如 "2026.0.0")——这是两套
     完全不同的版本编号体系,不是格式问题,没有"换算"这一说。
   以上三点,projections 语法本身没有任何 rename/查表机制,再怎么调
   模板字符串也做不到——`Spec.format()` 就是照抄 spec 属性的值。

**(a) vs (b) 初步对比,针对上面第 2 点(编译器/MPI 命名、版本号):**

| | (a) `spack module lmod refresh` 之后跑后处理脚本(重命名/建软链接) | (b) 接受 projections 拼出来的结果,不用脚本 |
|---|---|---|
| 能不能解决 | 能:脚本可以做任意字符串替换/查表(intel-oneapi-compilers→intel、甚至把 2026.0.0 换算成旧编号),自由度最高 | 不能:命名/版本号维持 Spack 原生的样子,永远对不上旧集群 |
| 额外维护成本 | 有:多一个脚本要维护,每次 `spack install`/`module refresh` 后都要重跑;要处理 Lmod 的 hash 目录、`.modulerc`、spider cache 等细节 | 没有:零额外脚本,Spack 生成什么就是什么,天然保持同步 |
| 风险 | 如果脚本直接"重命名"Spack 生成的文件,可能和 Spack 自己的 module 记录(按 DAG hash 记录 path/use_name,`spack module rm`/卸载软件时用)对不上,导致以后卸载/重装留下孤儿文件;如果改用"建软链接"而不是重命名能缓解一部分风险,但软链接本身也要在每次 refresh 后重新同步,并没有根治"多一个同步点"的问题 | 无额外风险,但要接受最终 module 名字跟旧集群不是逐字节一致(内容和结构完全对得上,只是编译器/MPI 那几个词、版本号不同) |
| 适用场景 | 如果终端用户/文档/脚本强依赖旧集群那几个具体字符串(比如 "intel"、"intel-mpi"、"2021.5.1"),或者有人已经写好依赖这些名字的下游脚本 | 如果用户能接受"语义等价、字符串不同"(即"这是 intel-oneapi-compilers 2026.0.0 编的",而不是必须写成"intel-2021.5.1") |

**最终决定(已确认,不再是"倾向"):选 (b)。** module key 里的
`intel-oneapi-compilers`/`intel-oneapi-mpi` 保持 Spack 原生包名,不写
重命名/建软链接的后处理脚本。理由:Step 5 那个真正的"硬骨头"(Lmod
目录层级、需要先 unlock 才能看到软件)已经用 `core_compilers` 纯配置
解决了,行为已经跟旧集群很接近;剩下的只是"编译器/MPI 那几个词、版本号
字符串不同,语义完全一致",专门为这个再加一个脚本、多背一个"每次
install/refresh 后都要重跑、还可能和 Spack 自己的 DAG hash 记录对不上
留下孤儿文件"的维护负担,不划算。如果以后真的发现下游有硬编码依赖旧
字符串（比如某个脚本 grep "intel-mpi"）,再单独评估要不要加脚本。

用真实 `spack install --fake` + `spack module lmod refresh`(不是模拟,
是真的跑出来的文件)在 cmake(mainstream CPU)、`bwa %nvhpc`(GPU 编译器)、
cosma(mainstream + MPI)三个代表性软件上验证过最终效果,文件路径原样
如下:
```
Core/cmake/3.31.11/intel-oneapi-compilers-2026.0.0.lua
Core/bwa/0.7.19/nvhpc-24.1.lua
Core/cosma/2.8.4/intel-oneapi-compilers-2026.0.0-intel-oneapi-mpi-2026.0.0.lua
```
（这次验证还顺带发现:`spack module lmod refresh` 会尝试给
`intel-oneapi-compilers`/`intel-oneapi-mpi` 这两个"编译器包"自己也生成
module,会去 source 一个 `vars.sh` 环境脚本;因为我们的 external prefix
是占位符,这一步会报错失败——真机上 oneAPI 装好之后要确认这个
`vars.sh` 路径是对的,不然这两个编译器自己的 module 生不出来。）

## GPU(+cuda)软件真实编译验证与 CUDA 版本分流

cp2k、lammps、namd 三个都已经在集群上用真实 `spack install +cuda
cuda_arch=80` 编译验证通过(独立的 `environments/gpu-test` +
`scripts/gpu-test-install.sh`,install_tree 独立、不碰 production)。
过程中挖出一长串真实的 CUDA 13.3 兼容性问题,修法都记在
`repos/spack_repo/rhel10_overrides/packages/{cp2k,namd,charmpp}/package.py`
的详细注释里,这里只列结论,细节看那几个文件 + git log。

### host 编译器:统一 `%gcc`,不是 `%nvhpc`
最早的约定是"GPU 软件用 nvhpc",实测发现 cp2k/lammps/namd 三个都不需要
nvhpc 当 host c/cxx 编译器(CUDA 部分各自有独立机制:CMake 原生
CUDA-as-language、namd 自己的 CUDADIR),强制用 nvhpc 反而拖累出一堆跟
GPU 代码无关的 nvhpc 编译器 bug(内部编译器崩溃、汇编不兼容指令、
stdatomic.h/converse.h 冲突)。`%oneapi` 也不行——nvcc 直接拒绝 icx
("option: icx is not supported in this version!"),NVIDIA 官方支持列表
里根本没有 icx。最终定为 `%gcc`(nvcc 支持范围内、且没有 nvhpc 那些
bug)。`config/specs.yaml` 里 cp2k/lammps/namd 三个 `+cuda` spec 都是
`... %gcc`。

### cp2k `+cuda` 遇到的真实 bug(3 个,都在
`repos/spack_repo/rhel10_overrides/packages/cp2k/package.py`)
1. **CMAKE_CUDA_ARCHITECTURES 探测坑**:cp2k 自己的 CMakeLists.txt 在
   `enable_language(CUDA)` 之前硬编码了一个"占位符"`set(CMAKE_CUDA_ARCHITECTURES 60)`
   (P100),这个探测阶段用的占位符值在 CUDA 13.3 里已经不支持
   (`nvcc fatal: Unsupported gpu architecture 'compute_60'`),导致探测
   直接失败——跟我们真正要的 `cuda_arch=80` 完全无关,命令行传的
   `-DCMAKE_CUDA_ARCHITECTURES=80` 会被这行硬编码覆盖掉。修法:用
   `filter_file` 把源码里那个 `60` 直接替换成真实的 cuda_arch。
   **踩过一个 Spack 内部机制的坑**:这个 hook 一开始挂在 `Cp2k` 包类上,
   `@run_before("cmake")` 完全不触发(无报错,静默失效)——查了
   `spack/lib/spack/spack/phase_callbacks.py` 才发现:Package 类上的
   `@run_before`/`@run_after` 钩子只会给"没有独立 Builder 子类"的老式包
   自动合并到 Builder 上;cp2k 有自己独立的 `CMakeBuilder`,钩子必须直接
   挂在 `CMakeBuilder` 上才会生效。
2. **cufftResult 枚举值被移除**:`src/offload/offload_fft.h` 里一个把
   cufft 错误码转字符串的 switch 语句,用到了
   `CUFFT_INCOMPLETE_PARAMETER_LIST`/`CUFFT_PARSE_ERROR`/
   `CUFFT_LICENSE_ERROR` 三个枚举值,CUDA 13.3 的 `cufft.h` 已经彻底删掉
   了(不是 deprecated,是真删除)。修法:把这三个 case 注释掉(函数本身
   没有 default 分支,但 switch 之后有 `return "<unknown>"` 兜底,注释掉
   完全安全)——这其实是照抄 upstream 自己在 HIP 那一侧已经用过的同款
   修法(`// case HIPFFT_LICENSE_ERROR:` 已经被注释掉了,只是 CUDA 那侧
   还没跟上)。
3. **MKL 不提供 pkg-config 版 fftw3**:cp2k 的 fftw-api 依赖默认会解析成
   external 的 `intel-oneapi-mkl`(全局默认 provider),但 cp2k 自己的
   `cmake/modules/FindFftw.cmake` 找不到 MKL 的 FFTW 兼容层(即使传了
   `-DCP2K_USE_FFTW3_WITH_MKL=ON`)。修法:spec 里强制 `^fftw`,让 cp2k
   的 fftw-api 依赖用真正 Spack 编译的 fftw(BLAS/LAPACK/ScaLAPACK 仍然
   走 MKL,不受影响)——lammps 也有同一个问题,同样用 `^fftw` 解决。

### lammps `+cuda` 遇到的真实 bug
跟 cp2k 一样的 MKL/fftw3 pkg-config 问题,同样用 `^fftw` 解决。另外
charmpp(namd 的依赖,不是 lammps 的)相关的坑不适用于 lammps。

### namd `+cuda` 遇到的一长串真实 bug(6 轮,详见
`repos/spack_repo/rhel10_overrides/packages/{namd,charmpp}/package.py`)
1. **charmpp 默认 build-target=LIBS 会连带编译不需要的 AMPI/ROMIO**,
   ROMIO 自己的 MPI-configure 自检在 netlrts backend(没有真 MPI)下必
   然失败。修法:namd 的 spec 里加 `^charmpp build-target=charm++`,只编
   译 namd 真正用到的 charm++ 本体。
2. **charmpp 的 `memory_order`/`<stdatomic.h>` 冲突**:charmpp 自己在
   `converse.h` 里手写了一份 `memory_order` 枚举,跟真正的
   `<stdatomic.h>`(这个集群的 `/project` 是 Lustre,`lustreapi.h` 需要
   真的 `<stdatomic.h>` 提供 `atomic_int`)冲突。第一次"假装
   `_STDATOMIC_H` 已经被 include 过"的修法本身有两个 bug(改坏了换行、
   又把真正的 `<stdatomic.h>` 挡在后面代码之外),最终改成直接
   `#include <stdatomic.h>`、把 charmpp 自己手写的枚举用 `#if 0` 禁掉。
3. **namd@2.14 的 CUDA kernel 用了旧式"纹理引用"API**
   (`texture<...> force_table;` + `tex1D(force_table,...)`),CUDA 13.3
   已经彻底删除了这套 API(不是 deprecated)。改用 **namd@3.0.3**(GPU
   后端已经改写成纹理对象 API)。namd 的 manual_download 包,3.0.3 这个
   版本 Spack 自带的 recipe 还没收录,在 override 里手动加了
   `version("3.0.3", sha256=...)`。
4. **`cudaDeviceProp.computeMode` 字段被移除**:namd@3.0.3 的
   `src/DeviceCUDA.C` 三处用 `.computeMode` 检测"prohibited"/
   "exclusive-process" GPU 模式,这个字段新版 CUDA Runtime API 已经删了。
   修法:把这三处判断改写成字面上"当作普通设备"的结果(`if(1`/`if(0)`),
   只改含 `.computeMode` 的那一行,其余多行条件不动。
5. **CUB/Thrust/libcu++ 合并成 CCCL,绕过版本检查的宏改名了**:namd 自己
   的 `arch/Linux-x86_64.cuda` 已经在传旧宏
   (`-DCUB_IGNORE_DEPRECATED_CPP_DIALECT`/`-DTHRUST_IGNORE_DEPRECATED_CPP_DIALECT`),
   CUDA 13.3 统一成了 `CCCL_IGNORE_DEPRECATED_CPP_DIALECT`,没跟上导致
   `#error CUB requires at least C++17` 照样触发。补上新宏之后,发现
   **CCCL 是真的需要 C++17**(不只是警告),`storage.h`/
   `numeric_limits_ext.h` 等头文件本身用了只有 C++14+ 才合法的多
   return 语句 `constexpr` 函数。最终把
   `CUDA_COMPILER_FLAGS = -m64 -std=c++11` 改成 `-std=c++17`(只影响
   nvcc 编译的 .cu 文件,不影响 g++ 编译的宿主代码,libstdc++ ABI 由
   另一个宏控制、不受 `-std=` 影响)。
6. **namd 自己的 kernel 代码直接调用了 CUDA 13.3 已经删除的 CUB 函数**
   (`cub::LaneMaskLt`/`cub::Min`/`cub::Max`,出现在
   `ComputeBondedCUDAKernel.cu`/`CudaTileListKernel.cu`)——这是真正参与
   数值计算的 GPU kernel 代码(warp 级线程协作、数值比较),不是构建配置
   或错误码字符串表,用户明确决定不去盲改这类代码(namd 源码许可证限
   制、看不到全貌,也没法真的跑 GPU 验证正确性)。

   **研究后发现根本不是 namd 版本问题**:NAMD 官方 3.0.3(已经是最新版)
   自己的 release notes 写的是 "Support for CUDA versions 9.1-12.x"——
   即便最新版也从没在 CUDA 13.x 上验证过,降级 namd 版本只会更糟(2.14
   连纹理对象 API 都没换)。**真正的修法是给 namd 单独配一个它真正支持
   的 CUDA 版本**:管理员(用户本人)在集群上独立装了一份 standalone
   CUDA 12.9.0 toolkit(`cuda_12.9.0_575.51.03_linux.run --silent
   --toolkit --toolkitpath=/usr/local/packages/cuda/12.9`,只装 toolkit
   不装驱动——现有驱动本来就支持更新的 13.3,向下兼容 12.9 完全没问题),
   在 `packages.yaml` 里注册成第二个 `cuda@12.9.0` external,namd 的
   spec 里显式 `^cuda@12.9.0`。cp2k/lammps 继续用默认的 `cuda@13.3.0`,
   两者互不干扰(已用 Python 直接遍历 environment 依赖图验证过,不是只
   看 `spack spec` 的文字输出——`spack spec`/`find -d` 的树状打印会因为
   dedup 逻辑产生误导性的省略,不能直接拿来判断某个 root 到底依赖哪个
   版本,必须用 `env.concrete_roots()` + `spec.traverse()` 编程式确认)。

最终 `config/specs.yaml` 里三个的完整 spec:
```
- cp2k +cuda cuda_arch=80 %gcc ^fftw
- lammps +cuda cuda_arch=80 %gcc ^fftw
- namd@3.0.3 +cuda cuda_arch=80 %gcc ^charmpp build-target=charm++ ^cuda@12.9.0
```

## Cluster-results 自动回传机制

集群上 sbatch 作业跑完后,日志会自动 push 回 GitHub 的 `cluster-results`
分支,本地/WSL 端只需要 `git pull` 就能直接看日志文件,不用再手动
复制粘贴。

- 机制:每个 install 脚本(`smoke-test-install.sh`/
  `tierN-test-install.sh`/`gpu-test-install.sh`)在开头 `source
  scripts/lib/push-results.sh` 并 `trap push_results EXIT`,脚本退出时
  (不管成功失败)自动把日志 commit 到一个**独立的 git worktree**
  (`/project/fchen14/spack-rhel10-results`,checkout 的是
  `cluster-results` 分支,不影响主 checkout 的分支/工作区状态),路径是
  `results/<job_name>/<时间戳>_job<jobid>/`,里面有日志文件和一个
  `EXIT_CODE` 标记文件,然后 push,失败会重试(fetch+rebase)最多 3 次。
- `scripts/push-latest-results.sh`:手动兜底脚本,给"Slurm 硬杀
  (walltime/OOM)导致 EXIT trap 根本没机会跑"这种情况用,手动指定
  job_name/job_id/日志路径/退出码调用同一个 `push_results` 函数。
- 集群侧认证:一开始想用 SSH deploy key,遇到 GitHub 显示 "Disabled by
  lonihpc"、一度怀疑是 SSH Certificate Authorities 组织策略(后来确认
  这个猜测是错的,`lonihpc` 不是 GitHub Enterprise,那只是升级推广位),
  根因没有查清楚,最终放弃 deploy key,改用**细粒度 Personal Access
  Token + `git config credential.helper store`**(明文缓存在
  `~/.git-credentials`),集群侧只需要 `git push`,已验证工作正常。
- 本地/WSL 端要看某次 job 的日志:
  ```
  cd /project/fchen14/spack-rhel10-results
  git fetch origin cluster-results && git merge --ff-only origin/cluster-results
  ```
  然后直接去 `results/<job_name>/` 下找对应时间戳的目录。

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
  - 最初写在 environments/hpc-software/{config,packages,modules,spack}.yaml
    里,后来按用户要求拆成了 environments/{dev-local,production}/
    spack.yaml + 共享的 config/{packages,modules}.yaml,见上面
    "Environment 目录结构"章节,hpc-software 目录已删除。
  - 重要:Spack v1.2.x 已经彻底去掉了 compilers.yaml,编译器改成在
    packages.yaml 里以 external package 形式声明(带 deprecation 迁移
    逻辑),所以没有单独的 compilers.yaml 文件。
  - 用 `spack -C environments/hpc-software ...`(当时还没拆分,这个
    environment 现在已经不存在了,后续验证都在 environments/dev-local
    下做)和 `spack env activate environments/hpc-software` 在本机
    (WSL2)做了 schema 校验 + 完整 `spack concretize`(全部 14 个目标
    软件都能 concretize 成功,没有真的 install)。发现的问题都已经记在对应
    yaml 文件的注释里,包括:mvapich2 全版本 deprecated 改用 mvapich、
    Spack 默认编译器 provider 顺序是 gcc 优先(已在 packages.yaml 里
    覆盖成 Intel oneAPI 优先)、amber 在 Spack 里只有 18/20 两个版本
    (没有旧集群例子里的 22)。
  - modules.yaml 已经从 Tcl 草稿切到 Lmod 并完成 Step 5(详见上面专门的
    "Step 5" 章节):用真实 concretize+生成的 module 路径验证过,通过把
    intel-oneapi-compilers/nvhpc/gcc 全部标成 `core_compilers` 解决了
    Lmod 强制的 compiler 层级问题(所有情况都能扁平落在 `Core/` 下,不用
    先 `module load <compiler>` 才能看到软件)。编译器/MPI 包名和版本号
    跟旧集群对不上的问题**已拍板**:不写重命名后处理脚本,保留 Spack
    原生包名(intel-oneapi-compilers/intel-oneapi-mpi)。用
    `spack install --fake` + `spack module lmod refresh` 真跑过 cmake/
    `bwa %nvhpc`/cosma 三个代表性软件确认最终效果。
  - 之后按用户要求把工具链简化成主流 Intel oneAPI + intel-oneapi-mpi,
    gcc 降级为 fallback(从 default provider 列表里去掉),nvhpc 只留给
    需要 GPU 的软件按 spec 单独 pin `%nvhpc`,不再作为 provider。
    mpich/mvapich 已从 packages.yaml 和 spack.yaml 的目标软件列表里删除。
    重新 concretize 验证过全部 12 个目标软件都默认落在
    `%oneapi@2026.0.0`;发现两个包级例外(非配置问题):amber 完全不声明
    编译器依赖,ambertools 固定用 %gcc 编译 c/cxx、只有 fortran 走
    %oneapi(ifx)。
  - CPU/GPU 硬件信息已确认并写入配置(详见上面"硬件信息"章节):
    `packages:all:target: [icelake]`、`packages:all:variants:
    cuda_arch=80`、CUDA external 从占位的 12.6 改成确认的 13.3.0。
    真实安装路径(oneAPI/nvhpc/CUDA 具体 prefix)还是占位符,标了
    TODO(cluster),真机确认后要替换。测出来一个真实的不兼容:Spack 的
    `amber` 包 `+cuda` 时硬编码上限 `cuda@:11.1`,跟 cuda@13.3.0 冲突,
    已让 amber 先保持纯 CPU,GPU 版 amber 怎么处理留待以后决定。本机
    (WSL2)识别成 skylake 不是 icelake,额外加了
    `concretizer:targets:host_compatible: false` 才能让 icelake
    偏好在本地生效(真机上跑在 icelake 节点则无影响)。
  - 按用户要求把 environments/hpc-software 拆成 environments/dev-local +
    environments/production,共享配置提到 config/{packages,modules}.yaml
    (见上面"Environment 目录结构"章节)。用 dev-local 重新跑过一遍完整
    验证:`spack concretize` 干净通过(target=icelake、cuda_arch:=80 都
    生效);`spack install --fake` 装了整个 environment,除了两个
    `py-pip` 变体因为本机没有真实 python3 二进制而失败(--fake 安装的
    已知限制,跟这次拆分无关)之外全部成功,包括 cmake/namd/lammps/cosma
    这几个代表性软件;`spack module lmod refresh` 在新的 module 目录下
    生成出了正确的文件,比如
    `Core/namd/2.14/nvhpc-24.1-cuda-13.3.0-intel-oneapi-mpi-2026.0.0.lua`
    (cuda 版本号已经是新的 13.3.0)。验证完之后卸载了所有 fake 包并清空
    了 spack-install/,没有留下测试垃圾。
  - dev-local/production 的 `specs:` 列表核对过是完全一致的(拆分时
    diff 过,没有分叉),已经提到 `config/specs.yaml` 作为唯一来源,配
    `scripts/render-specs.py` 生成进两份 spack.yaml(见上面"改软件清单
    流程"章节)。跑了两遍脚本确认幂等(第二遍全部 unchanged,`--check`
    退出码 0)。同时把 amber+cuda 不兼容的说明更新成更精确的版本
    (`cuda@11.0:11.1`,用 `spack info amber` 验证过两条 depends_on 取
    交集的结果,不只是"上限 11.1")。当前完整软件清单(12 个,matlab
    照常排除在外):amber, ambertools, boost, bowtie2, bwa, cmake, mamba,
    cosma, cp2k, lammps(+cuda cuda_arch=80 %nvhpc), metis, namd(+cuda
    cuda_arch=80 %nvhpc)。
  - 新建了 environments/smoke-test/spack.yaml(不动 dev-local/
    production):3 个代表性软件 cmake/cosma/`bwa %nvhpc`,install_tree
    和 module roots 都指到集群上一个独立的临时目录
    (/project/fchen14/spack-rhel10-smoke-test/...),不是
    /usr/local/packages。配套写了 scripts/smoke-test-install.sh 当
    sbatch 模板(4 核、2 小时、不要 GPU,因为这几个包本身不需要在 GPU
    上跑)。这个脚本后来被(在集群上真实跑过一次之后)手动改过:换成了
    真实的 spack 路径 `/project/fchen14/spack-tool`(不是本仓库自带的
    `spack/` clone)、加了 `SPACK_PYTHON=/usr/bin/python3`、填了真实的
    `--partition=gpu2`/`--account=loni_loniadmin1`(LONI 集群)——这些
    改动原样保留,没有还原。
  - 用户要求把 cuda 也从 external 改成 Spack 自装,追问后确认其实是想
    把 intel-oneapi-compilers/intel-oneapi-mpi/nvhpc/cuda 四个都改。
    实测发现两个真实的 Spack concretizer 限制(细节见上面"自包含编译器
    工具链的调查结论"章节):(1) 同一条 `spack install` 命令里不能混装
    "现装的编译器"和"用这个编译器编译的东西",必须一个一个单独装;
    (2) 就算一个一个装,"reuse" 逻辑也会不听 `packages:all:providers`
    的偏好顺序,把 nvhpc 这类真正装出来的编译器复用到不相关的小软件包
    上,甚至导致本来该用 gcc 兜底的 `cuda` 反而 concretize 失败。拿这
    两个实测结果去问用户,最终决定只把 cuda 改成自装(`require:
    "@13.3.0"`),intel-oneapi-compilers/intel-oneapi-mpi/nvhpc 三个
    维持 external + `buildable: false`。顺带发现并修正了一个版本号错误:
    intel-oneapi-mpi 用的是自己独立的 2021.x 版本号体系,不是 oneAPI
    主版本号,"2026.0.0" 根本不存在,已改成真实存在的最新版 2021.18.0
    (`spack versions intel-oneapi-mpi` 验证过)。重新 concretize 过
    dev-local 全部 12 个软件,确认干净无报错。评估过
    scripts/smoke-test-install.sh 的 walltime/磁盘:因为最终只有 cuda
    改自装,而 smoke-test 的 3 个软件(cmake/cosma/`bwa %nvhpc`)都不
    依赖独立的 cuda 包(concretize 验证过,cuda 没出现在依赖图里),
    所以这次改动对 smoke-test 的实际下载/编译量没有影响,2 小时 walltime
    不需要跟着调整。
  - **推翻了上一条"只有 cuda 自装"的决定,还试过"两阶段安装"方案想保留
    全自装,最终四个全部改回 external**——完整过程见上面"编译器/MPI/
    CUDA external 路径:最终决定"章节。集群上的真实手动安装路径已经
    确认并填入(不再是占位符):intel-oneapi-compilers@2026.1.0、
    intel-oneapi-mpi@2021.18.0、nvhpc@26.5、cuda@13.3.0,前两者
    prefix 都在 `/usr/local/packages/compilers/intel-oneapi-2026`,
    nvhpc 在 `/usr/local/packages/compilers/nvhpc/Linux_x86_64/26.5`,
    cuda 在 `/usr/local/packages/cuda/13.3`。intel-oneapi-compilers/
    nvhpc 两个额外加了 `extra_attributes.compilers`(真实 icx/icpx/ifx、
    nvc/nvc++/nvfortran 可执行文件路径)和 spec 里的
    `languages:='c,c++,fortran'`,不然 Spack v1.2 的新编译器模型下会报
    `exec: None: not found` 之类的错。另外新增了 intel-oneapi-mkl 这个
    external,设成默认 BLAS/LAPACK provider,修了 cosma 的 "Invalid Host
    BLAS backend"。`modules.yaml` 的 `core_compilers` 版本号(之前的
    2026.0.0/24.1 是笔误,和 packages.yaml 真实版本不匹配导致 Lmod 精确
    版本匹配失败、退回嵌套目录布局)已同步改成 2026.1.0/26.5。
  - `scripts/smoke-test-install.sh` 修了一个真实复现过的 bug:`REPO_ROOT`
    原来靠 `readlink -f "$0"` 解析脚本自身路径,如果 sbatch 用相对路径
    提交、且计算节点作业启动 cwd 跟提交目录不一致,会解析错(这就是
    之前 "No such environment" 报错的根因)。改成优先用 Slurm 自己保证
    设置的 `SLURM_SUBMIT_DIR`,原逻辑降级为只在手动跑(不在 Slurm 下)时
    的 fallback。
  - **加入了 Tier 1 批次**(eigen, git, gsl, hwloc, valgrind,加上已经在
    清单里的 boost/cmake)到 `config/specs.yaml`,目的是在正式清单规模
    下验证批量编译流程。为了不碰生产路径 `/usr/local/packages`(命名还
    没最终定),照着 `environments/smoke-test` 的套路新建了
    `environments/tier1-test/spack.yaml`(只列这 7 个包,不 include 整个
    `config/specs.yaml`,install_tree 指向独立的
    `/project/fchen14/spack-rhel10-tier1-test/`,不跟 smoke-test 共用
    目录)和配套的 `scripts/tier1-test-install.sh`(sbatch 模板,4 小时
    walltime——比 smoke-test 的 2 小时长,因为 git 拉出一整条 gcc
    autotools 引导链的小包,加上 boost/curl/perl/openssl 因为两种编译器
    各建一份而重复编译)。
  - 修了一个真实的包编译问题:`tar@1.35` 在 AlmaLinux 10(glibc 2.39)
    上因为 gnulib 的 ACL `*_at` 函数兼容声明跟系统头文件冲突,编译报
    `conflicting types for 'acl_get_file_at'`。根因是 `gettext` 默认
    `+tar`(打包 example 归档的可选功能)把 tar 拉了进来;在
    `packages.yaml` 里加了 `gettext: variants: ~tar` 关掉这个功能绕开了
    坏的编译路径,gettext 本身给 git 用的国际化功能不受影响。
  - **Tier 1(eigen/git/gsl/hwloc/valgrind + 已在清单里的 boost/cmake)在
    集群上真实编译全部通过**,已正式纳入 `config/specs.yaml`。同时又
    加了 Tier 2(fftw/hdf5/netcdf-c/netcdf-cxx4/netcdf-fortran/
    parallel-netcdf/parmetis/superlu-dist/hypre/petsc,都依赖
    intel-oneapi-mpi)和 Tier 3(bowtie2/hisat2/star/spades/vcftools/
    revbayes,生信工具),每一批都照 Tier 1 的套路建了独立的
    `environments/tierN-test` + `scripts/tierN-test-install.sh`
    (install_tree 各自独立、不复用),Tier 2 也已真实编译通过。
  - **新增了 `repos/spack_repo/rhel10_overrides` 这个自定义 Spack package
    repo**,用来给 builtin 包打site-specific补丁,不用手改/fork整个
    recipe:通过 `config/repos.yaml`(所有 environment 都 include)注册,
    优先级天然高于 `builtin`(builtin 只在 Spack 最低优先级的
    "defaults" scope 注册,environment scope 的配置总是赢)。已验证的
    正确用法:继承 builtin 的包类(比如
    `class Python(BuiltinPython)`)、只加一个 `@run_before(...)` 钩子——
    Spack 的 `DirectiveMeta` 会把父类已注册的 `version()`/`variant()`/
    `depends_on()` 等指令重新对子类生效,不是"fork整个几百行 recipe"。
    第一个用例:python@3.13.5 的 `_tkinter` 模块在这个集群的 Tcl 9.0
    下编译链接都成功、但运行时 `undefined symbol: Tcl_ListObjGetElements`
    崩溃(CPython/Tcl9 已知上游问题
    github.com/python/cpython/issues/104363),`packages.yaml` 层面的
    variant/环境变量都拦不住(configure 阶段对可选 stdlib 扩展模块是
    "无条件先构建、运行时自检失败才丢弃"的新逻辑),真正管用的办法是在
    `@run_before("build")` 钩子里把 `Modules/Setup.local` 写成
    `*disabled*\n_tkinter\n`——这是 CPython 自己
    `Modules/makesetup` 脚本里"first rule wins"的官方设计机制(专门
    留给用户在 Setup.local 里禁用模块用的),因为 Setup.local 在文件
    列表里排在自动生成的 Setup.stdlib 前面处理。**踩过一个坑**:第一次
    以为改完 repo 优先级后没生效(_tkinter 照样被编译),查了半天才发现
    是环境的 `spack.lock` 是改动前生成的旧锁文件,`spack install`
    默认只装锁文件里已经定好的东西,不会因为 `repos.yaml` 变了就自动
    重新决定用哪个 repo 的 recipe——必须 `spack concretize --fresh -f`
    重新锁一次,新 lock 里的 python 节点才会指向我们的 override。
  - **发现并解决了一个共享文件系统(`/project`)上的 Spack 数据库锁死锁
    问题**:`environments/tierN-test` 的真实 `spack install` 连续三次
    (job 41/42/43)卡死在完全同一个位置(revbayes 装完之后~7分27秒,
    跟前面装没装成功、失败没失败无关),`strace` 确认卡在
    `fcntl(F_SETLK)` 对 `.spack-db/lock` 拿 `EAGAIN`,但 `lslocks`
    显示没有任何进程真正持有这把锁——是 `/project` 这类共享文件系统
    fcntl 锁释放语义不可靠导致的死锁,不是并发/某个包失败触发的偶发
    问题(后来把 `scripts/tier3-test-install.sh` 改成严格串行、一次
    只跑一个 spec 的 `spack install` 之后照样在两次独立调用之间卡死,
    证明确实跟并发无关)。最终修法:`environments/tier3-test/spack.yaml`
    里加 `config: locks: false` 彻底关掉 Spack 自己的文件锁——串行安装
    下本来就没有真正的并发写风险,关掉锁是安全的。
  - **spades@4.0.0 真实编译一路挖出 6 个独立问题**,记在
    `repos/spack_repo/rhel10_overrides/packages/spades/package.py` 里
    (継承 builtin 的 `Spades`,加钩子/`flag_handler`,不改 Spack 自己
    的 recipe):(1) 内嵌 mimalloc 快照的 CMakeLists.txt 给
    `CMAKE_CXX_COMPILER_ID MATCHES "Intel"` 加 `-Kc++`,这个正则连
    `"IntelLLVM"`(icx/icpx)也匹配上,upstream mimalloc 后来修过这个
    bug(加了 `AND NOT ... MATCHES "IntelLLVM"`),但 spades 打包的是
    修复前的快照;(2)(3)(4) spades 自己代码里三处真实的复制粘贴笔误
    (`key_with_hash.hpp` 引用了别的类才有的 `is_minimal_`成员、
    `flat_set.hpp`/`flat_map.hpp` 的 `swap()` 都把 `other.data_` 写成
    `other.data`)和内嵌 `lexy` 库的一处笔误(`_colum_nr` 少个 "n"),
    这几个 bug 长年没被发现是因为 C++ 模板成员函数只有真被调用时才编译,
    换了 icpx/新版 libstdc++ 才触发实例化;(5) `mpmc_bounded.hpp` 用
    `__GNUC__`/`_LIBCPP_VERSION` 判断该 `#include <atomic>` 还是过时的
    `<cstdatomic>`(C++11 定案前的草案头文件名,早不存在了),icpx 因为
    伪装低版本 `__GNUC__` 又不定义 `_LIBCPP_VERSION`(我们链接的是
    libstdc++不是libc++),踩进了这条判断 20 年前就该淘汰的死分支;
    (6) 内嵌 `blaze` 线性代数库一个真实的宏一致性设计缺陷:
    `SIMDfloat`/`SIMDdouble` 的底层类型只看有没有 AVX512
    (`BLAZE_AVX512F_MODE`)就定成 512 位的 `__m512`,但
    `floor()`/`ceil()`/`round()`/`trunc()` 的具体实现还额外要求有
    Intel SVML 或 SLEEF 库才会真的生成 512 位版本,没有的话默默退化成
    256 位的 AVX 实现——多数机器没有 AVX512 所以从没人踩到,我们
    `target: icelake` 支持 AVX512 又没配 SVML/SLEEF,正好踩中;这个用
    `flag_handler` 单独给 spades 加 `-mno-avx512f` 绕开,没有去改 blaze
    源码(它至少还有 3 个姊妹文件是同一个模式)。另外发现 Spack 的
    `spades` package.py 把 `sra`(NCBI VDB/SRA 支持)和 `tools`(额外
    子工具,含一个叫 pathracer、代码多年没跟进、用了过时 C++0x 写法的
    附属程序)这两个 variant 都默认开着,但上游 SPAdes 自己默认是关的
    (`sra` 官方文档写明"due to possible compatibility issues"),关掉
    `~sra ~tools` 避免了不必要的额外编译面。**Tier 3 六个包最终全部
    真实编译通过**(`spack -e environments/tier3-test find` 确认
    6/6 已装)。
  - **建立了 cluster-results 自动回传机制**(sbatch 作业日志自动 push
    回 GitHub,本地 `git pull` 直接看),详见上面专门的"Cluster-results
    自动回传机制"章节。
  - **cp2k/lammps/namd 三个 `+cuda cuda_arch=80` 全部真实编译验证通过**
    (2026-09-14 ~ 09-16,独立的 `environments/gpu-test`),过程中挖出一
    长串真实的 CUDA 13.3 兼容性 bug(cp2k 的 CMAKE_CUDA_ARCHITECTURES
    探测坑、cufftResult 枚举值移除;namd 的纹理引用 API 移除、
    computeMode 字段移除、CCCL 宏改名+真实需要 C++17、kernel 代码直接
    调用已删除的 CUB 函数),namd 最终确认自己上游都没在 CUDA 13.x 上
    验证过、需要专门配一份 `cuda@12.9.0` 才能编译。三个都已经正式纳入
    `config/specs.yaml`。完整过程详见上面专门的"GPU(+cuda)软件真实编译
    验证与 CUDA 版本分流"章节,还没挪到 production。
