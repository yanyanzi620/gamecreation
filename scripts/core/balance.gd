extends RefCounted
class_name Balance
# ============================================================
# 净化协议 · 全局平衡数值表
#
# ★ 这里是唯一的数值入口。改数字只改这个文件，各模块不要再写死。
# ★ 每条注释写两件事：这个数是什么、调大调小会怎样。
#
# 结构：
#   场地      ARENA_* / CELL / GRID_*
#   病毒      VIRUS_* 通用，BLOB_* / BAND_* / CHAIN_* 分形态
#   玩家      PLAYER_*
#   手段      JET_* / PURGE_* / PICKUP_* / BLOCK_* / FUSE_*
#   经济      NUTRIENT_PER_CORPSE / *_COST
# ============================================================


# ------------------------------------------------------------ 场地
const ARENA_W := 1600.0
const ARENA_H := 1000.0
const ARENA_PAD := 30.0        # 病毒不许长到离边这么近的区域
const CELL := 30.0             # 粗格边长；只影响密度判定，不影响手感
const GRID_W := 54             # = ARENA_W / CELL
const GRID_H := 34             # = ARENA_H / CELL


# ============================================================ 病毒 · 通用
const VIRUS_MAX_LIVE := 6000   # 存活上限；撞上限就停繁殖（性能红线，别乱抬）
const VIRUS_MAX_CORPSE := 1800 # 尸体池上限；满了新尸体不生成

# ★ 扩散速度的总闸门：复制冷却 = 代际时间
#   调大 -> 整体变慢（最终密度不变，只是更晚长满）
#   调小 -> 整体变快
const VIRUS_COOL_MIN := 1.40
const VIRUS_COOL_MAX := 2.50

const VIRUS_PROBE_DIST := 30.0 # 探路距离，习惯上等于 CELL
const VIRUS_R_MIN := 4.5       # 粒子视觉半径下限
const VIRUS_R_MAX := 8.0       # 粒子视觉半径上限；只影响观感，不影响碰撞


# ============================================================ 病毒 · 圆周 BLOB
# CAP 是「密度上限」不是「速度」：调小会显得稀疏，调大只是能堆得更密
const BLOB_CAP := 10
const BLOB_SPAWN_D_MIN := 14.0 # 子粒子落地距离；调小 = 更黏、更圆
const BLOB_SPAWN_D_MAX := 26.0
const BLOB_W := 1.0            # 方向权重（各向同性，一般不用改）


# ============================================================ 病毒 · 带状 BAND
const BAND_CAP := 6
const BAND_SPAWN_D_MIN := 14.0
const BAND_SPAWN_D_MAX := 26.0
const BAND_AXIS_WANDER := 0.07  # 每次繁殖让主轴折一次的概率；调大 = 更弯
const BAND_WANDER_DEG := 20.0   # 单次折线幅度
# 方向权重：正前方强推，±45° 给一点点宽度，反向只用于回填
const BAND_W_FRONT := 6.5
const BAND_W_45 := 1.2          # 调大 = 带子更宽
const BAND_W_SIDE := 0.5
const BAND_W_BACK := 0.3


# ============================================================ 病毒 · 跳跃链 CHAIN
# 单点传播：不做邻格生长，直接往前方扇形区域随机落一颗
const CHAIN_CAP := 2
const CHAIN_SPREAD_DEG := 38.0  # 落点相对主轴的最大偏角；调大 = 扇得更开
const CHAIN_STEP_MIN := 70.0    # 每代往前跳多远；这是「无处不达」的来源
const CHAIN_STEP_MAX := 150.0
const CHAIN_AXIS_WANDER_DEG := 14.0


# ============================================================ 病毒 · 尸体
const CORPSE_LIFE := 30.0       # 尸体存在多久后自然消失
const CORPSE_PICK_DELAY := 1.0  # 躺多久之后才可被拾取（保证玩家先看到疤）


# ============================================================ 玩家
const PLAYER_SPEED := 320.0
const PLAYER_R := 22.0          # 单元视觉半径；目前碰撞按中心点算


# ============================================================ 手段 · 射流
const JET_LENGTH := 320.0        # 射程；调大 = 一次性清得更深
const JET_HALF_ANGLE_DEG := 16.0 # 半角；调大 = 扇形更宽、更容易扫到
const JET_COOLDOWN := 0.50       # 两发之间最短间隔
const JET_VIS_SEC := 0.30        # 弹道残影停留时间（纯表现）
const JET_ARC_STEPS := 18        # 扇形绘制细分（纯表现）


# ============================================================ 手段 · 净化场（贴身自动）
const PURGE_RADIUS := 108.0      # 站在病毒里也不至于瞬间被淹
const PURGE_PER_SEC := 55.0      # 每秒消融几颗


# ============================================================ 手段 · 养分拾取（自动）
const PICKUP_RADIUS := 200.0     # 比射程小 -> 远端战果收不回来，必须往前走
const PICKUP_PER_SEC := 45.0     # 每秒最多收几颗尸体
const MOTE_SPEED := 460.0        # 光点飞回速度（纯表现）
const MOTE_MAX := 80             # 同时在场光点上限；满了就先不吃，不会丢养分


# ============================================================ 手段 · 阻隔带
const BLOCK_LEN := 260.0         # 固定长度；调大 = 更容易整条封死
const BLOCK_OFFSET := 140.0      # 落在单元正前方多远
const BLOCK_ARM := 0.45          # 闪烁多久才生效（生效前只减速、不拦人）
const BLOCK_LIFE := 30.0         # 生效后存活多久，到点自溶
const BLOCK_SLACK := 12.0        # 端点容差
const BLOCK_COOLDOWN := 0.20     # 只防手滑双击，真正的限制是养分


# ============================================================ 手段 · 引信
const FUSE_KILL := 85.0          # 内圈：圆盘/带状/链，进圈即消融
const FUSE_PULL := 220.0         # 外圈：只对跳跃链生效的引力范围
const FUSE_SPEED := 250.0        # 链被拽的速度；调大 = 吸得更快更狠
const FUSE_LIFE := 3.0           # 引信维持多久
const FUSE_OFFSET := 180.0       # 落在单元正前方多远
const FUSE_MAX := 3              # 同时最多几枚


# ============================================================ 经济
const NUTRIENT_PER_CORPSE := 1   # 一颗尸体换多少养分
const BLOCK_COST := 30           # 一条阻隔带的花费
const FUSE_COST := 40            # 一枚引信的花费
const FUSE_COOLDOWN := 5.0       # 引信冷却
