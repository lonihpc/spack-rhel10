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

## 硬件信息(已确认,不再是"待确认")
- CPU target:icelake(`packages:all:target: [icelake]`)。
- GPU:Ampere 级(如 A100),`cuda_arch=80`,作为
  `packages:all:variants` 的默认值,GPU 软件(namd、lammps 等)在
  spack.yaml 里再显式加 `+cuda cuda_arch=80 %nvhpc`。
- CUDA 版本:pin 到 13.3.0,匹配 GPU 驱动支持的 CUDA 版本。**最新决定
  (已改过一次):改成 Spack 自装**(`packages:cuda:require: "@13.3.0"`),
  不再是 external——`require:` 保证版本号还是精确锁定在 13.3.0,只是
  改成让 Spack 自己下载安装这份用户态 CUDA Toolkit,而不是指向集群已有的
  安装路径。intel-oneapi-compilers/intel-oneapi-mpi/nvhpc 这三个**仍然是
  external**,没有跟着一起改——原因见下面"自包含编译器工具链的调查
  结论"章节,那里有实测出来的、目前绕不过去的 Spack concretizer 限制。
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

## 自包含编译器工具链的调查结论(已确认:只有 cuda 自装,其余仍 external)

用户曾经要求把 intel-oneapi-compilers、intel-oneapi-mpi、nvhpc、cuda
四个"基础组件"全部改成 Spack 自装(不用 external),理由是"即使系统
安装验证可用也不用 external,统一由 Spack 管理,可复现"。实测下来:

- **cuda 单独自装:完全没问题。** cuda 不提供 c/cxx/fortran 这几个
  "编译器虚包"(它不是编译器),所以不会碰到下面这两个坑。已经采用
  (`packages:cuda:require: "@13.3.0"`,不再 external)。
- **intel-oneapi-compilers/intel-oneapi-mpi/nvhpc 也一起自装:实测遇到
  两个真实的、目前没有干净解法的 Spack concretizer 限制**,已经放弃,
  三个继续保持 external + `buildable: false`:
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
  这两个限制是实测验证的(不是猜的),但没有再深入去修——如果以后真的
  想把这三个也改成自装,预期至少要解决这两个问题,可能需要更细致的
  安装顺序控制、显式 hash pin,或者等 Spack 版本/concretizer 改进。

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
4. 配置 MPI/CUDA(主流是 intel-oneapi-mpi(external),GPU 软件配 nvhpc
   系列(external)+ CUDA 13.3.0(Spack 自装,见下面"硬件信息"/"自包含
   编译器工具链的调查结论"章节);不再引入 mvapich/mpich。备注:
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
