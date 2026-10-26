# Cache tag 宽度独立源码审查

2026-10-14；只读审查 `fpga/build/full_integration_20261013/cache_tag_probe_20261014_214406_338740/` 的实际diff及源码，不修改源/约束，不运行PDS/仿真，不停止D/E/G。baseline按D `sources.json` 逐项重算290项SHA，全部一致。candidate实际只改 `rtl/geometry/rgb_tile_cache.sv` 与 `geometry_rgb_pipeline.sv`；本报告不替代另行执行的差分/流水线测试或原生结果。

结论：**当前主板5/3 tile参数、pipeline既有2..4096尺寸合法域内，没有发现阻止实施的源码问题。此结论不覆盖全部旧泛型配置的逐拍等价。** 正式推广仍须核实具体候选的功能/原生/整板验证，单位资源变化不证明可布通。

## 当前合法域为何可无损缩窄

`geometry_rgb_pipeline`原来的legal已要求width/height均2..4096及正fx/fy；candidate只向cache增加MAX_FRAME_WIDTH/HEIGHT=4096，其他pipeline逻辑不变。实际 `geometry_frame_processor.sv:37` 未覆盖TILE参数，沿用pipeline的TILE_X_BITS=5/TILE_Y_BITS=3。缓存运行时尺寸仍由同一个start捕获，未修改frame_ready或cache_start时序。

尺寸上限M、tile跨度T时，最大合法tile编号为ceil(M/T)-1；候选 `(M+T-1)/T` 及 `max(1,$clog2(tile_count))` 正确。例：4096/32=128个tile→X7；4096/8=512个tile→Y9。非整除4097/32、4097/8会得到129/513及8/10位，避免遗漏边缘tile；MAX=2且32×8 tile只有一个tile，仍有1/1位合法vector。MAX<=32768、合法TILE位数1..7时，此加法/乘法常量没有32位溢出。

进入有效miss的sx/sy来自原有prefix_mask的非负及≤(width/height-1)*4096检查、原有邻点clamp，因而tx/ty不会超过上述最大tile编号。比较仍使用全integer tx/ty，未把坐标先截断；只有保存的tag_x/y及registered query_x/y缩窄且宽度配对一致。requested_x/y及公开fill_tile_x/y仍为12位，其hold与赋值时机完全未变。当前X7/Y9零扩展到12位不会产生别名。可行TILE1..7且两维之和8时，pipeline<=4096也都在12位tile请求范围内。

tag_valid的reset清零、query_hit_valid来源与 `query_hit_valid && tag-coordinate equality` 门控未改变；tag发布仍要求FILL末项/LAST正确且无fill_error/drain_fault。无效tag载荷继续可为X，不用初始化/缩短descriptor来假冒资源收益。无效/越界坐标的mask路径、duplicate广播、bank冲突检查也未修改。

SETS、SLOTS、BANK_WORDS、四parity数据bank及地址、QUEUE_DEPTH/FIFO计数、替换/pin策略、一个outstanding refill、FILL_WORDS及bank_write条件全部不变。LOOKUP/REQUEST/FILL/SELECT/REQUERY状态、push/pop/query_transfer/serve/read_issue、弹性寄存器valid/ready与所有reset/refill握手也未改；源码缩窄不减少cache数据容量、队列容量或II=1协议吞吐。物理时序/吞吐能力仍需实际验证。

## 必须明确的泛型合同变化

默认MAX_FRAME=32768、默认16×16 tile下，tag11/11位覆盖所有原来2..32768尺寸，tile最大2047，12位公开refill限制不新增尺寸拒绝。当前主板32×8、MAX=4096也没有新拒绝。

但默认MAX=32768、TILE_X_BITS=1/TILE_Y_BITS=7（2×128）时，旧RTL会ACK宽度8193..32768，而12位requested_x不能表达tile4096及以上；旧tag也是12位，原实现并未完整支持该域。候选新增 `frame_width<=4096*TILE_W`，因此最大accepted width为8192，旧更大请求改为config_rejected。反向128×2的height同理。**这属于泛型接收合同变化及显式拒绝旧不可表达范围，不能称为所有旧accepted配置等价。** pipeline本来上限4096，故这些限制在其合法域不产生新拒绝；尺寸拒绝时尺寸/enable/tag invalidation沿用未接受start的保持逻辑，其余已有活动帧仍按原状态机继续。

新增PARAMETERS_VALID还要求MAX范围2..32768、两维TILE_BITS范围1..7且和8：非法参数在simulation新增$fatal，在可正常elaborate的综合实例中hardware admission为假。旧代码虽已有“256 pixels/四parity”假设，却没有同样的强制拒绝，因此同样是泛型参数合同收紧。没有声明支持所有原可elaborate的其他tile面积、奇数parity形状或非法MAX参数。FILL_PIXELS/SET_BITS/QUEUE_DEPTH的旧边界行为本次没有新增验证，不可据新guard宣称通用参数全部受支持。

候选散列：cache=`04a409b3ef18fb4631f9c388440c8d66fe89d437a446e6d96c2dda28006b9c06`；pipeline=`c62ba0ae3d03e3b7f17ef36b4fd8360e69e1ab230796c147d36f2e9211f76654`。对应D基线分别`a6613e0a8e7e28e82b61836f0b3782cdbfe7dcaa3363d22a61abb01206acd2b6`、`b99f4b26878245b00c8dbf18f2500c9cac4c17981b7353f5817321fb681d061c`。没有复用旧B网名、没有增加例外、没有修改当前路由来源。
