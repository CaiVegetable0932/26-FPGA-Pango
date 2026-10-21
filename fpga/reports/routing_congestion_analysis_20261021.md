# 布线拥塞分析（只读）

终结迭代：49；分析文件数：50；区域桶：60

## 每轮趋势（节选）

| iter | entries | max | >=30 | >=50 | sum |
| --- | --- | --- | --- | --- | --- |
| 0 | 77367 | 106 | 560 | 220 | 215290 |
| 3 | 63139 | 100 | 336 | 97 | 157081 |
| 6 | 55533 | 82 | 185 | 31 | 127371 |
| 9 | 47626 | 72 | 84 | 14 | 102136 |
| 12 | 41965 | 59 | 64 | 10 | 86077 |
| 15 | 38213 | 57 | 50 | 4 | 76653 |
| 18 | 35755 | 61 | 50 | 5 | 70962 |
| 21 | 33903 | 60 | 51 | 7 | 66416 |
| 24 | 32884 | 61 | 47 | 6 | 64180 |
| 27 | 31630 | 56 | 47 | 3 | 61714 |
| 30 | 30747 | 60 | 45 | 3 | 59891 |
| 33 | 30146 | 64 | 37 | 5 | 58762 |
| 36 | 29613 | 60 | 36 | 5 | 57667 |
| 39 | 29445 | 64 | 42 | 6 | 57660 |
| 42 | 29027 | 64 | 39 | 9 | 56399 |
| 45 | 28629 | 60 | 35 | 2 | 55899 |
| 48 | 28429 | 61 | 50 | 5 | 56072 |

## 终结迭代按层级（前 25）

| prefix | count | sum | max |
| --- | --- | --- | --- |
| `core/processor/processor` | 4411 | 7476 | 51 |
| `core/fabric/frames` | 2489 | 5572 | 47 |
| `core/fabric/dma` | 1817 | 3149 | 19 |
| `core/processor/memory_refill` | 852 | 2577 | 61 |
| `I_ips_ddr_top/u_ddrphy_top/ddrphy_slice_top` | 1047 | 2050 | 40 |
| `core_reset_n` | 121 | 940 | 38 |
| `core/network/snapshot_output.snapshot` | 491 | 898 | 33 |
| `core/reader/unpack` | 142 | 562 | 43 |
| `core/snapshot_connected.snapshots/reader` | 209 | 553 | 41 |
| `core/isp_writer/writer` | 271 | 523 | 23 |
| `I_ips_ddr_top/u_ddrphy_top/ddrphy_calib_top` | 198 | 470 | 25 |
| `core/raw_writer/writer` | 272 | 401 | 14 |
| `core/snapshot_connected.snapshots/pair` | 262 | 390 | 35 |
| `core/snapshot_connected.snapshots/copy` | 113 | 327 | 25 |
| `boot/N2726` | 42 | 309 | 25 |
| `core/network/raw` | 155 | 290 | 21 |
| `I_ips_ddr_top/u_ips_ddrc_top/mcdq_wdatapath` | 83 | 232 | 29 |
| `camera_domain_reset_n` | 28 | 169 | 39 |
| `core/snapshot_connected.snapshots/N73` | 35 | 169 | 17 |
| `core/geometries/N44` | 28 | 168 | 16 |
| `core/N899` | 28 | 159 | 17 |
| `core/processor/result_bridge` | 96 | 145 | 5 |
| `core/N903` | 29 | 138 | 12 |
| `I_ips_ddr_top/u_ddrphy_top/ddrphy_rst_n` | 16 | 129 | 48 |
| `boot/read_response` | 22 | 120 | 14 |

## 终结迭代按坐标区域（前 20，桶 60）

| x0 | y0 | count | sum | max |
| --- | --- | --- | --- | --- |
| 180 | 720 | 668 | 1709 | 49 |
| 240 | 660 | 764 | 1683 | 27 |
| 180 | 540 | 743 | 1646 | 54 |
| 240 | 540 | 808 | 1642 | 20 |
| 240 | 720 | 712 | 1619 | 61 |
| 240 | 780 | 768 | 1601 | 44 |
| 180 | 600 | 794 | 1538 | 25 |
| 180 | 480 | 763 | 1503 | 38 |
| 240 | 600 | 722 | 1471 | 27 |
| 180 | 660 | 695 | 1457 | 35 |
| 240 | 420 | 549 | 1425 | 47 |
| 300 | 660 | 665 | 1355 | 14 |
| 180 | 420 | 673 | 1314 | 35 |
| 300 | 600 | 643 | 1289 | 39 |
| 300 | 780 | 537 | 1188 | 19 |
| 300 | 720 | 538 | 1159 | 48 |
| 240 | 900 | 491 | 1154 | 41 |
| 300 | 540 | 624 | 1142 | 29 |
| 240 | 360 | 443 | 1127 | 46 |
| 240 | 480 | 598 | 1108 | 33 |

## 终结迭代最热网线（前 20）

| value | net | iter0 value |
| --- | --- | --- |
| 61 | `core/processor/memory_refill/write_beat_6` | 64 |
| 54 | `core/geo_src_slot [1]` | 63 |
| 51 | `core/processor/processor/geometry/projective_path.u_step/xy/origin_y [31]` | 45 |
| 50 | `core/processor/memory_refill/write_beat_2` | 59 |
| 49 | `core/processor/memory_refill/N1341_6` | 63 |
| 48 | `I_ips_ddr_top/u_ddrphy_top/ddrphy_rst_n` | 2 |
| 47 | `core/fabric/frames/banks[4].pool/N410_0` | 64 |
| 47 | `core/processor/memory_refill/N1341_10` | 57 |
| 46 | `core/fabric/frames/banks[1].pool/N7589` | 42 |
| 44 | `core/processor/memory_refill/quad [0]` | 56 |
| 44 | `_N43` | 56 |
| 43 | `core/reader/unpack/aligned_rows.local_capture[0].capture_enable` | 63 |
| 43 | `core/processor/memory_refill/N1341 [5]` | 56 |
| 42 | `display/reader/_N266519_1` | 54 |
| 41 | `core/snapshot_connected.snapshots/reader/unpack/N22` | 1 |
| 41 | `core/fabric/frames/banks[4].pool/N410` | 1 |
| 40 | `I_ips_ddr_top/u_ddrphy_top/ddrphy_slice_top/ddrphy_slice_rddata_align/dqs_read_valid_r [2]` | 62 |
| 40 | `core/fabric/frames/banks[1].pool/rsp [2887]` | 1 |
| 39 | `camera_domain_reset_n` | 1 |
| 38 | `core/geo_src_slot [0]` | 63 |

## 网格拥塞图热点格（前 20）

| value | x | y |
| --- | --- | --- |
| 24 | 40 | 98 |
| 22 | 33 | 93 |
| 22 | 32 | 104 |
| 21 | 36 | 106 |
| 20 | 45 | 62 |
| 20 | 39 | 95 |
| 20 | 39 | 85 |
| 20 | 34 | 95 |
| 20 | 31 | 104 |
| 19 | 40 | 88 |
| 19 | 33 | 105 |
| 19 | 32 | 96 |
| 19 | 31 | 120 |
| 19 | 30 | 90 |
| 19 | 29 | 97 |
| 18 | 45 | 92 |
| 18 | 42 | 108 |
| 18 | 42 | 105 |
| 18 | 38 | 91 |
| 18 | 37 | 98 |
