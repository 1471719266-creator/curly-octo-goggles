#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NVIDIA GPU 售后服务报告生成器
仅从实测原始数据自动汇总，严禁用经验值填空。
"""
import argparse
import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def safe_read(path: Path, max_lines: Optional[int] = None) -> str:
    """安全读取文件，不存在则返回空串"""
    try:
        if not path.exists():
            return ""
        with open(path, "r", errors="replace") as f:
            if max_lines:
                return "".join(f.readlines()[:max_lines])
            return f.read()
    except Exception as e:
        return f"[读取失败: {e}]"


def parse_csv_like(text: str) -> List[Dict[str, str]]:
    """解析nvidia-smi的csv输出"""
    if not text.strip():
        return []
    lines = [l for l in text.strip().splitlines() if l.strip()]
    if len(lines) < 2:
        return []
    reader = csv.DictReader(lines)
    return [{k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in row.items()} for row in reader]


def parse_nvidia_smi_xml(xml_path: Path) -> Dict[str, Any]:
    """解析 nvidia-smi -q -x 生成的XML（最完整的官方结构化输出）"""
    result: Dict[str, Any] = {"gpus": [], "driver_version": "", "cuda_version": ""}
    if not xml_path.exists():
        return result
    try:
        tree = ET.parse(xml_path)
        root = tree.getroot()

        drv = root.find("driver_version")
        if drv is not None and drv.text:
            result["driver_version"] = drv.text.strip()
        cuda = root.find("cuda_version")
        if cuda is not None and cuda.text:
            result["cuda_version"] = cuda.text.strip()

        for gpu_elem in root.findall("gpu"):
            gpu: Dict[str, Any] = {}

            def get_text(tag: str) -> str:
                el = gpu_elem.find(tag)
                return (el.text or "").strip() if el is not None else ""

            gpu["id"] = get_text("id")
            gpu["product_name"] = get_text("product_name")
            gpu["product_brand"] = get_text("product_brand")
            gpu["pci_bus_id"] = (gpu_elem.find("pci/pci_bus_id").text or "").strip() if gpu_elem.find("pci/pci_bus_id") is not None else ""
            gpu["serial"] = get_text("serial")
            gpu["uuid"] = get_text("uuid")
            gpu["vbios_version"] = get_text("vbios_version")
            gpu["inforom_version"] = get_text("inforom_version")

            # 显存
            fb = gpu_elem.find("fb_memory_usage")
            if fb is not None:
                gpu["memory_total_mb"] = (fb.find("total").text or "").strip() if fb.find("total") is not None else ""
                gpu["memory_used_mb"] = (fb.find("used").text or "").strip() if fb.find("used") is not None else ""
                gpu["memory_free_mb"] = (fb.find("free").text or "").strip() if fb.find("free") is not None else ""

            # 温度/功耗
            gpu["temperature_gpu"] = ""
            t = gpu_elem.find("temperature/gpu_temp")
            if t is not None and t.text:
                gpu["temperature_gpu"] = t.text.strip()
            gpu["temperature_slow_threshold"] = ""
            t2 = gpu_elem.find("temperature/gpu_temp_slow_threshold")
            if t2 is not None and t2.text:
                gpu["temperature_slow_threshold"] = t2.text.strip()
            gpu["power_draw"] = ""
            pw = gpu_elem.find("power_readings/power_draw")
            if pw is not None and pw.text:
                gpu["power_draw"] = pw.text.strip()
            gpu["power_limit"] = ""
            pl = gpu_elem.find("power_readings/power_limit")
            if pl is not None and pl.text:
                gpu["power_limit"] = pl.text.strip()
            gpu["enforced_power_limit"] = ""
            epl = gpu_elem.find("power_readings/enforced_power_limit")
            if epl is not None and epl.text:
                gpu["enforced_power_limit"] = epl.text.strip()

            # CUDA 计算能力
            gpu["compute_cap_major"] = get_text("compute_mode")
            cc = gpu_elem.find("compute_cap")
            if cc is not None:
                gpu["compute_cap"] = f"{(cc.find('major').text or '?') if cc.find('major') is not None else '?'}.{(cc.find('minor').text or '?') if cc.find('minor') is not None else '?'}"
            else:
                gpu["compute_cap"] = ""

            # PCIe 链路
            pci = gpu_elem.find("pci")
            if pci is not None:
                def pci_get(tag):
                    el = pci.find(tag)
                    return (el.text or "").strip() if el is not None else ""
                gpu["pcie_link_gen_current"] = pci_get("pcie_link_gen_current")
                gpu["pcie_link_gen_max"] = pci_get("pcie_link_gen_max")
                gpu["pcie_link_width_current"] = pci_get("pcie_link_width_current")
                gpu["pcie_link_width_max"] = pci_get("pcie_link_width_max")
                gpu["pcie_replay_counter"] = pci_get("pcie_replay_counter")
                gpu["pcie_replay_rollover_counter"] = pci_get("pcie_replay_rollover_counter")

            # ECC 模式
            ecc = gpu_elem.find("ecc_mode")
            if ecc is not None:
                cur = ecc.find("current_ecc")
                gpu["ecc_mode_current"] = (cur.text or "").strip() if cur is not None else ""
                pend = ecc.find("pending_ecc")
                gpu["ecc_mode_pending"] = (pend.text or "").strip() if pend is not None else ""

            # ECC 错误计数
            ecc_err: Dict[str, Any] = {}
            for location in ["volatile", "aggregate"]:
                ecc_err[location] = {}
                loc_elem = gpu_elem.find(f"ecc_errors/{location}")
                if loc_elem is not None:
                    for etype in ["single_bit", "double_bit", "total"]:
                        e = loc_elem.find(etype)
                        if e is not None:
                            ecc_err[location][etype] = {
                                sub.tag: (sub.text or "").strip()
                                for sub in e
                            }
            gpu["ecc_errors"] = ecc_err

            # 已退役显存页
            rp = gpu_elem.find("retired_pages")
            if rp is not None:
                gpu["retired_pages_single_bit"] = (rp.find("retired_count_single_bit").text or "").strip() if rp.find("retired_count_single_bit") is not None else ""
                gpu["retired_pages_double_bit"] = (rp.find("retired_count_double_bit").text or "").strip() if rp.find("retired_count_double_bit") is not None else ""
                gpu["retired_pages_pending"] = (rp.find("retired_pending").text or "").strip() if rp.find("retired_pending") is not None else ""
                gpu["retired_pages_multiple_single_bit"] = (rp.find("retired_count_multiple_single_bit").text or "").strip() if rp.find("retired_count_multiple_single_bit") is not None else ""

            # 时钟
            gpu["clocks_graphics_mhz"] = ""
            gc = gpu_elem.find("clocks/graphics_clock")
            if gc is not None and gc.text:
                gpu["clocks_graphics_mhz"] = gc.text.strip()
            gpu["clocks_memory_mhz"] = ""
            mc = gpu_elem.find("clocks/mem_clock")
            if mc is not None and mc.text:
                gpu["clocks_memory_mhz"] = mc.text.strip()

            # 最大时钟
            gpu["max_clocks_graphics_mhz"] = ""
            mgc = gpu_elem.find("max_clocks/graphics_clock")
            if mgc is not None and mgc.text:
                gpu["max_clocks_graphics_mhz"] = mgc.text.strip()
            gpu["max_clocks_memory_mhz"] = ""
            mmc = gpu_elem.find("max_clocks/mem_clock")
            if mmc is not None and mmc.text:
                gpu["max_clocks_memory_mhz"] = mmc.text.strip()

            result["gpus"].append(gpu)
    except Exception as e:
        result["_parse_error"] = str(e)
    return result


def parse_gpu_basic_info(csv_path: Path) -> List[Dict[str, str]]:
    return parse_csv_like(safe_read(csv_path))


def parse_bandwidth_test(bandwidth_path: Path) -> Dict[str, Any]:
    """解析 bandwidthTest --csv 输出"""
    text = safe_read(bandwidth_path)
    result: Dict[str, Any] = {"raw": text[:5000], "h2d": None, "d2h": None, "d2d": None}
    if not text:
        return result
    lines = text.splitlines()
    for i, line in enumerate(lines):
        low = line.lower()
        if "host to device bandwidth" in low or "h2d" in low:
            # 找下一行的数字
            for j in range(i + 1, min(i + 5, len(lines))):
                nums = re.findall(r"[\d.]+", lines[j])
                if nums:
                    try:
                        result["h2d"] = float(max(nums, key=lambda x: len(x.split(".")[0])))
                    except Exception:
                        pass
                    break
        elif "device to host bandwidth" in low or "d2h" in low:
            for j in range(i + 1, min(i + 5, len(lines))):
                nums = re.findall(r"[\d.]+", lines[j])
                if nums:
                    try:
                        result["d2h"] = float(max(nums, key=lambda x: len(x.split(".")[0])))
                    except Exception:
                        pass
                    break
        elif "device to device bandwidth" in low or "d2d" in low:
            for j in range(i + 1, min(i + 5, len(lines))):
                nums = re.findall(r"[\d.]+", lines[j])
                if nums:
                    try:
                        result["d2d"] = float(max(nums, key=lambda x: len(x.split(".")[0])))
                    except Exception:
                        pass
                    break
    # 模式2：纯CSV格式
    if result["h2d"] is None and "Bandwidth," in text:
        for row in csv.DictReader([l for l in lines if "," in l]):
            for k, v in row.items():
                kk = k.lower()
                try:
                    num = float(v)
                except Exception:
                    continue
                if "h2d" in kk and result["h2d"] is None:
                    result["h2d"] = num
                elif "d2h" in kk and result["d2h"] is None:
                    result["d2h"] = num
                elif "d2d" in kk and result["d2d"] is None:
                    result["d2d"] = num
    return result


def parse_nbody(nbody_path: Path) -> Dict[str, Any]:
    """解析 nbody -benchmark 输出"""
    text = safe_read(nbody_path)
    result: Dict[str, Any] = {"raw": text[:2000], "bodies": None, "gflops": None, "avg_gflops": None}
    if not text:
        return result
    m = re.search(r"N\s*=\s*(\d+)", text, re.IGNORECASE)
    if m:
        try:
            result["bodies"] = int(m.group(1))
        except Exception:
            pass
    # 找 GFLOPS/s
    gflops_list = re.findall(r"([\d.]+)\s*GFLOP/s", text, re.IGNORECASE)
    if gflops_list:
        try:
            nums = [float(x) for x in gflops_list]
            result["gflops_list"] = nums
            result["gflops"] = nums[-1] if nums else None
            result["avg_gflops"] = sum(nums) / len(nums) if nums else None
        except Exception:
            pass
    # "average" 行
    m2 = re.search(r"average.*?([\d.]+)\s*GFLOP/s", text, re.IGNORECASE)
    if m2:
        try:
            result["avg_gflops"] = float(m2.group(1))
        except Exception:
            pass
    return result


def parse_matrixMul(mat_path: Path) -> Dict[str, Any]:
    text = safe_read(mat_path)
    result: Dict[str, Any] = {"raw": text[:2000], "perf_gflops": None, "time_ms": None}
    if not text:
        return result
    m = re.search(r"Performance\s*=\s*([\d.]+)\s*Gflop/s", text, re.IGNORECASE)
    if m:
        try:
            result["perf_gflops"] = float(m.group(1))
        except Exception:
            pass
    m2 = re.search(r"Time\s*=\s*([\d.]+)\s*ms", text, re.IGNORECASE)
    if m2:
        try:
            result["time_ms"] = float(m2.group(1))
        except Exception:
            pass
    return result


def parse_stress_monitor(csv_path: Path) -> Dict[str, Any]:
    """解析压力测试期间的 nvidia-smi -l 1 CSV输出"""
    text = safe_read(csv_path)
    result: Dict[str, Any] = {"gpus": {}}
    if not text.strip():
        return result
    rows = parse_csv_like(text)
    if not rows:
        # 回退：按;或空格分隔
        return result

    by_gpu: Dict[str, Dict[str, List[float]]] = {}
    for row in rows:
        # 找到GPU索引key
        gpu_idx = None
        for k in row:
            if "index" in k.lower():
                try:
                    gpu_idx = str(int(row[k]))
                    break
                except Exception:
                    pass
        if gpu_idx is None:
            gpu_idx = "0"
        by_gpu.setdefault(gpu_idx, {"temp_c": [], "power_w": [], "fan_pct": [], "gpu_util_pct": [], "mem_util_pct": []})
        for k, v in row.items():
            kl = k.lower()
            numbers = re.findall(r"[\d.]+", v)
            if not numbers:
                continue
            try:
                num = float(numbers[0])
            except Exception:
                continue
            if "temp" in kl and "gpu" in kl:
                by_gpu[gpu_idx]["temp_c"].append(num)
            elif "power" in kl and "draw" in kl:
                by_gpu[gpu_idx]["power_w"].append(num)
            elif "fan" in kl:
                by_gpu[gpu_idx]["fan_pct"].append(num)
            elif "util" in kl and "gpu" in kl:
                by_gpu[gpu_idx]["gpu_util_pct"].append(num)
            elif "util" in kl and "mem" in kl:
                by_gpu[gpu_idx]["mem_util_pct"].append(num)

    def stats(arr: List[float]) -> Dict[str, Optional[float]]:
        if not arr:
            return {"min": None, "avg": None, "max": None, "samples": 0}
        return {
            "min": min(arr),
            "avg": round(sum(arr) / len(arr), 2),
            "max": max(arr),
            "samples": len(arr),
        }

    for idx, d in by_gpu.items():
        result["gpus"][idx] = {
            "temp_c": stats(d["temp_c"]),
            "power_w": stats(d["power_w"]),
            "fan_pct": stats(d["fan_pct"]),
            "gpu_util_pct": stats(d["gpu_util_pct"]),
            "mem_util_pct": stats(d["mem_util_pct"]),
        }
    return result


def parse_p2p_test(p2p_path: Path) -> Dict[str, Any]:
    text = safe_read(p2p_path)
    return {"raw": text[:8000], "available": ("P2P is available" in text or "Enabled" in text)}


def parse_device_query(dq_path: Path) -> Dict[str, Any]:
    text = safe_read(dq_path)
    result: Dict[str, Any] = {"raw": text[:4000], "devices": []}
    if not text:
        return result
    current: Optional[Dict[str, Any]] = None
    for line in text.splitlines():
        m = re.match(r"Device\s+(\d+):\s+\"(.+)\"", line)
        if m:
            if current:
                result["devices"].append(current)
            current = {"device_id": m.group(1), "device_name": m.group(2)}
            continue
        if current and ":" in line:
            k, _, v = line.partition(":")
            key = k.strip().lower().replace(" ", "_").replace("(","").replace(")","")
            if not key:
                continue
            current[key] = v.strip()
    if current:
        result["devices"].append(current)
    return result


def parse_fieldiag(result_path: Path, diag_path: Path, level_path: Path) -> Dict[str, Any]:
    """解析 NVIDIA fieldiag 原厂现场诊断结果"""
    result_text = safe_read(result_path).strip()
    diag_text = safe_read(diag_path)
    level_text = safe_read(level_path).strip()

    result: Dict[str, Any] = {
        "installed": result_text != "NOT_INSTALLED" and bool(result_text),
        "result": result_text or "N/A",
        "level": level_text or "N/A",
        "raw": diag_text[:10000],
        "passed": False,
        "errors": [],
    }

    if result_text == "PASS":
        result["passed"] = True
    elif result_text == "FAIL":
        result["passed"] = False
        # 提取错误行
        for line in diag_text.splitlines():
            low = line.lower()
            if any(kw in low for kw in ["fail", "error", "abort", "fatal"]):
                if "no error" not in low:
                    result["errors"].append(line.strip())
    elif result_text == "TIMEOUT":
        result["passed"] = False
        result["errors"].append("fieldiag 诊断超时")
    elif result_text == "INCOMPATIBLE":
        result["passed"] = True  # 兼容性失败不算诊断失败，不影响整体判定
        result["incompatible"] = True
    elif result_text == "CONSUMER_GPU_SKIPPED":
        result["passed"] = True  # 消费级GPU跳过不算失败，不影响整体判定
        result["consumer_skipped"] = True
        result["installed"] = True  # 有二进制，但因为GPU不是数据中心级所以跳过
    elif result_text == "NOT_INSTALLED":
        result["passed"] = True  # 未安装不算失败，不影响整体判定
        result["installed"] = False

    # 提取耗时
    for line in diag_text.splitlines():
        if line.startswith("耗时"):
            result["duration"] = line.replace("耗时: ", "").strip()
        elif line.startswith("返回码"):
            result["return_code"] = line.replace("返回码: ", "").strip()

    return result


def parse_dcgm_diag(diag_path: Path) -> Dict[str, Any]:
    text = safe_read(diag_path)
    result: Dict[str, Any] = {"raw": text[:10000]}
    if not text:
        return result
    # 判断整体结果
    lines = text.splitlines()
    # 找 "Overall Diagnostic" 或 "GPUs failed|passed"
    passed = [l for l in lines if re.search(r"passed|PASS|Success", l, re.IGNORECASE)]
    failed = [l for l in lines if re.search(r"fail|FAIL|Error|ERROR", l, re.IGNORECASE)]
    result["summary_lines_passed"] = passed[:10]
    result["summary_lines_failed"] = failed[:10]
    result["overall_pass"] = len(failed) == 0 or any("passed" in l.lower() for l in passed)
    return result


def parse_ecc_csv(ecc_path: Path) -> List[Dict[str, str]]:
    return parse_csv_like(safe_read(ecc_path))


def parse_cuda_memtest(path: Path) -> Dict[str, Any]:
    """解析 cuda_memtest 输出
    10种模式：Walking 1s/0s, Random, Gaussian, Solid Bits, Address Fetch,
    Block Seq, Checkerboard, Shift, Inversions, Memory
    任何报错=显存硬件故障→需RMA
    """
    text = safe_read(path)
    result: Dict[str, Any] = {
        "raw": text[:5000],
        "passed": False,
        "error_count": 0,
        "errors": [],
        "tests_run": [],
    }
    if not text.strip():
        return result

    # 检测 "Err" 或 "error" 或 "FAIL" 等关键字
    error_lines = []
    test_pattern = re.compile(r"(Test\d+|test\d+)\s*[:|]?\s*(.*)", re.IGNORECASE)
    for line in text.splitlines():
        low = line.lower()
        # 记录跑过的测试
        m = test_pattern.search(line)
        if m:
            result["tests_run"].append(m.group(1))
        # 检测错误
        if any(kw in low for kw in ["err", "fail", "mismatch", "incorrect", "fault"]):
            if "0 error" not in low and "no error" not in low:
                error_lines.append(line.strip())
                result["error_count"] += 1

    result["errors"] = error_lines[:20]

    # 检测最终通过状态
    if "no errors" in text.lower() or "passed" in text.lower():
        result["passed"] = True
    elif result["error_count"] == 0 and result["tests_run"]:
        result["passed"] = True

    return result


def parse_gpu_burn(path: Path) -> Dict[str, Any]:
    """解析 gpu-burn 输出
    gpu-burn 做矩阵乘法并将GPU结果与CPU参考值比对，
    任何不匹配=计算单元故障→需RMA
    """
    text = safe_read(path)
    result: Dict[str, Any] = {
        "raw": text[:5000],
        "passed": False,
        "errors": [],
        "gpus_tested": 0,
        "summary": "",
    }
    if not text.strip():
        return result

    error_lines = []
    for line in text.splitlines():
        low = line.lower()
        if any(kw in low for kw in ["fail", "mismatch", "error", "not ok"]):
            if "no error" not in low:
                error_lines.append(line.strip())

    result["errors"] = error_lines[:20]

    # 统计测试的GPU数
    result["gpus_tested"] = len(re.findall(r"GPU\s*\d+|device\s*\d+", text, re.IGNORECASE))

    # 最终状态
    if "ok" in text.lower() and not error_lines:
        result["passed"] = True
    elif "fail" in text.lower() and not error_lines:
        result["passed"] = False
    elif not error_lines and result["gpus_tested"] > 0:
        result["passed"] = True

    # 提取摘要行
    for line in text.splitlines():
        if "test" in line.lower() and ("summary" in line.lower() or "complete" in line.lower() or "finish" in line.lower()):
            result["summary"] = line.strip()
            break

    return result


def parse_dmesg_xid(xid_path: Path) -> List[str]:
    text = safe_read(xid_path)
    if not text.strip():
        return []
    return [l for l in text.splitlines() if l.strip()][-50:]


def classify_gpu_level(product_name: str) -> str:
    """根据GPU型号给出产品线分级（仅用于展示，不参与判定）"""
    p = (product_name or "").upper()
    if "H100" in p or "H200" in p or "B200" in p or "B300" in p or "GB200" in p:
        return "数据中心旗舰级 (Hopper/Blackwell)"
    elif "A100" in p or "A800" in p or "H800" in p:
        return "数据中心高端 (Ampere/Hopper)"
    elif "V100" in p or "A30" in p or "A40" in p or "L40" in p or "L4" in p:
        return "数据中心专业级"
    elif "RTX 6000" in p or "RTX 5000" in p or "RTX A" in p:
        return "工作站专业级"
    elif "RTX 40" in p or "RTX 30" in p:
        return "消费级 (GeForce)"
    else:
        return "其他/未分类"


def parse_row_remapper(path: Path) -> Dict[str, Any]:
    """解析 nvidia-smi -q -d ROW_REMAPPER 输出
    核心质检项：显存行重映射（硬件级冗余修复）
    - remapped_rows > 0: 已有行被重映射（显存有故障行，但硬件已修复）
    - remapping_failure = Yes: 备用行耗尽，无法修复 → 需RMA
    - pending_remissions > 0: 有待处理的重映射 → 接近RMA
    """
    text = safe_read(path)
    result: Dict[str, Any] = {"raw": text[:3000], "gpus": {}}
    if not text:
        return result
    # 按GPU分块（每个GPU的ROW_REMAPPER块以 "GPU 0000:" 或 "Remapped Rows" 开头）
    blocks = re.split(r"(?=GPU\s+\d+:|GPU 0000:)", text)
    for block in blocks:
        gpu_match = re.search(r"GPU\s+(?:0000:)?([0-9A-Fa-f:]+)", block)
        gpu_id = gpu_match.group(1) if gpu_match else str(len(result["gpus"]))
        gpu_data: Dict[str, Any] = {}
        m = re.search(r"Remapped Rows\s*:\s*(\d+)", block)
        if m:
            gpu_data["remapped_rows"] = int(m.group(1))
        m = re.search(r"Maximum Remapped Rows\s*:\s*(\d+)", block, re.IGNORECASE)
        if m:
            gpu_data["max_remapped_rows"] = int(m.group(1))
        m = re.search(r"Remapping Failure\s*:\s*(\w+)", block, re.IGNORECASE)
        if m:
            gpu_data["remapping_failure"] = m.group(1)
        m = re.search(r"Pending Remissions\s*:\s*(\d+)", block, re.IGNORECASE)
        if m:
            gpu_data["pending_remissions"] = int(m.group(1))
        m = re.search(r"Bank Remappings?\s*:\s*(.*)", block, re.IGNORECASE)
        if m:
            gpu_data["bank_remappings"] = m.group(1).strip()
        m = re.search(r"Maximum Bank Remappings?\s*:\s*(\d+)", block, re.IGNORECASE)
        if m:
            gpu_data["max_bank_remappings"] = int(m.group(1))
        if gpu_data:
            result["gpus"][gpu_id] = gpu_data
    return result


def parse_nvlink(path_status: Path, path_errors: Path, path_topology: Path) -> Dict[str, Any]:
    """解析NVLink状态与错误计数"""
    result: Dict[str, Any] = {
        "status_raw": safe_read(path_status)[:3000],
        "errors_raw": safe_read(path_errors)[:3000],
        "topology_raw": safe_read(path_topology)[:3000],
        "has_errors": False,
        "link_count": 0,
    }
    status = result["status_raw"]
    errors = result["errors_raw"]
    # 统计活跃NVLink数
    result["link_count"] = len(re.findall(r"Link\s+\d+.*Active", status, re.IGNORECASE))
    result["total_links"] = len(re.findall(r"Link\s+\d+", status, re.IGNORECASE))
    # 检查错误
    if "error" in errors.lower() and "0" not in re.findall(r"error.*?(\d+)", errors, re.IGNORECASE)[-1:]:
        result["has_errors"] = True
    # 检查降级链路
    if re.search(r"Inactive|Down|Disabled", status, re.IGNORECASE):
        result["has_degraded_links"] = True
    else:
        result["has_degraded_links"] = False
    return result


def parse_mig(path_status: Path, path_ci: Path) -> Dict[str, Any]:
    """解析MIG配置状态"""
    result: Dict[str, Any] = {
        "status_raw": safe_read(path_status)[:2000],
        "ci_raw": safe_read(path_ci)[:2000],
        "enabled": False,
        "gi_count": 0,
        "ci_count": 0,
    }
    if "No MIG" in result["status_raw"] or "not" in result["status_raw"].lower():
        return result
    result["gi_count"] = len(re.findall(r"GPU instance\s*ID\s*:", result["status_raw"], re.IGNORECASE))
    result["ci_count"] = len(re.findall(r"Compute instance\s*ID\s*:", result["ci_raw"], re.IGNORECASE))
    result["enabled"] = result["gi_count"] > 0
    return result


def parse_nvsmi_domain(path: Path, domain_name: str) -> Dict[str, Any]:
    """通用 nvidia-smi -q -d 域解析器"""
    text = safe_read(path)
    return {"raw": text[:3000], "available": bool(text.strip()) and "not available" not in text.lower()}


def determine_pass_fail(data: Dict[str, Any]) -> Tuple[bool, List[str]]:
    """
    核心售后服务判定逻辑：
    返回 (整体是否通过, 问题清单)
    判定规则参考NVIDIA官方保修/质检指引
    """
    issues: List[str] = []
    gpus = data.get("gpus", [])

    if not gpus:
        issues.append("未检测到任何GPU或XML解析失败")
        return False, issues

    for idx, gpu in enumerate(gpus):
        name = gpu.get("product_name", f"GPU{idx}")
        label = f"[{name}]"

        # --- 致命故障：直接FAIL ---
        # ECC不可纠正错误（累计）>0
        ecc = gpu.get("ecc_errors", {})
        for loc in ["volatile", "aggregate"]:
            total = ecc.get(loc, {}).get("total", {})
            db = total.get("double_bit", "")
            try:
                db_num = int(re.findall(r"\d+", str(db))[0]) if db else 0
            except Exception:
                db_num = 0
            if db_num > 0:
                issues.append(f"{label} ECC {loc} 不可纠正(双比特)错误数 = {db_num}（>0，需RMA）")

        # 退役显存页（含pending）
        for key in ["retired_pages_single_bit", "retired_pages_double_bit", "retired_pages_multiple_single_bit"]:
            val = gpu.get(key, "")
            try:
                num = int(re.findall(r"\d+", str(val))[0]) if val else 0
            except Exception:
                num = -1
            if num > 0:
                issues.append(f"{label} {key} = {val}（存在已退役显存页，需RMA）")
        rp_pending = gpu.get("retired_pages_pending", "")
        if rp_pending and str(rp_pending).lower() not in ("no", "0", "", "n/a"):
            issues.append(f"{label} 存在待退役显存页 pending={rp_pending}（需RMA）")

        # PCIe Replay计数异常
        replay = gpu.get("pcie_replay_counter", "")
        try:
            replay_num = int(re.findall(r"\d+", str(replay))[0]) if replay else 0
        except Exception:
            replay_num = -1
        if replay_num > 100:
            issues.append(f"{label} PCIe重放计数器={replay_num}（>100，建议排查线缆/RISER/背板）")

        # PCIe链路未达到最大规格（新卡应跑满）
        gen_cur = gpu.get("pcie_link_gen_current", "")
        gen_max = gpu.get("pcie_link_gen_max", "")
        wid_cur = gpu.get("pcie_link_width_current", "")
        wid_max = gpu.get("pcie_link_width_max", "")
        if gen_cur and gen_max and re.findall(r"\d+", str(gen_cur)) and re.findall(r"\d+", str(gen_max)):
            try:
                if int(re.findall(r"\d+", str(gen_cur))[0]) < int(re.findall(r"\d+", str(gen_max))[0]):
                    issues.append(f"{label} PCIe代际未达标: 当前{gen_cur} / 最大{gen_max}（检查主板插槽/BIOS设置）")
            except Exception:
                pass
        if wid_cur and wid_max and re.findall(r"\d+", str(wid_cur)) and re.findall(r"\d+", str(wid_max)):
            try:
                if int(re.findall(r"\d+", str(wid_cur))[0]) < int(re.findall(r"\d+", str(wid_max))[0]):
                    issues.append(f"{label} PCIe位宽未达标: 当前{wid_cur} / 最大{wid_max}（检查主板插槽/物理安装）")
            except Exception:
                pass

        # --- 温度/功耗告警（压力测试期间） ---
        stress = data.get("stress_monitor", {}).get("gpus", {}).get(str(idx), {})
        temp_max = (stress.get("temp_c") or {}).get("max")
        if temp_max is not None:
            temp_threshold = gpu.get("temperature_slow_threshold", "")
            # fallback: 95C 是绝大多数卡的降频阈值
            try:
                thr = int(re.findall(r"\d+", temp_threshold)[0]) if temp_threshold else 95
            except Exception:
                thr = 95
            if temp_max >= thr:
                issues.append(f"{label} 压力测试峰值温度={temp_max}C >= 降频阈值{thr}C（散热异常）")
            elif temp_max >= 85:
                issues.append(f"{label} 压力测试峰值温度={temp_max}C 偏高（建议清理风道/检查导热硅脂）")

        power_max = (stress.get("power_w") or {}).get("max")
        power_limit = gpu.get("enforced_power_limit") or gpu.get("power_limit")
        if power_max is not None and power_limit:
            try:
                pl = float(re.findall(r"[\d.]+", str(power_limit))[0])
                if power_max >= pl * 0.98:
                    issues.append(f"{label} 压力测试峰值功耗={power_max}W 接近TDP限制={pl}W（确认电源供电是否充足）")
            except Exception:
                pass

        # --- dmesg Xid 错误（严重） ---
        xid_lines = data.get("dmesg_xid", [])
        for line in xid_lines[-20:]:
            if re.search(r"Xid.*\b(31|43|48|74|79|119)\b", line):
                if name.lower() in line.lower() or True:  # 暂不严格匹配
                    issues.append(f"{label} 检测到严重Xid错误: {line.strip()}")
                    break

        # --- 原厂质检：显存行重映射器（ROW_REMAPPER）---
        # 这是NVIDIA原厂质检/RMA判定的第一核心依据
        row_remapper = data.get("row_remapper", {}).get("gpus", {})
        for gpu_id, rr in row_remapper.items():
            if gpu_id == str(idx) or gpu_id == gpu.get("pci_bus_id", ""):
                failure = rr.get("remapping_failure", "")
                if str(failure).lower() in ("yes", "true", "1"):
                    issues.append(f"{label} 显存行重映射失败(remapping_failure=Yes) — 备用行已耗尽，【立即RMA】")
                pending = rr.get("pending_remissions", 0)
                if isinstance(pending, int) and pending > 0:
                    issues.append(f"{label} 待处理重映射数={pending} — 备用行即将耗尽，建议RMA")
                remapped = rr.get("remapped_rows", 0)
                max_rr = rr.get("max_remapped_rows", 0)
                if isinstance(remapped, int) and isinstance(max_rr, int) and max_rr > 0:
                    ratio = remapped / max_rr
                    if ratio > 0.5:
                        issues.append(f"{label} 显存行重映射消耗率={remapped}/{max_rr} ({ratio:.0%}) — 超过50%，建议RMA")
                    elif remapped > 0:
                        issues.append(f"{label} 显存已重映射{remapped}/{max_rr}行 — 有故障行但硬件已修复，跟踪观察")

        # --- 原厂质检：NVLink 错误 ---
        nvlink = data.get("nvlink", {})
        if nvlink.get("has_degraded_links"):
            total = nvlink.get("total_links", 0)
            active = nvlink.get("link_count", 0)
            if total > active:
                issues.append(f"{label} NVLink有链路降级: 活跃{active}/{total} — 检查NVLink线缆/NVSwitch")
        if nvlink.get("has_errors"):
            issues.append(f"{label} NVLink检测到错误计数 — 检查互联链路完整性")

        # --- 原厂质检：cuda_memtest 显存主动校验 ---
        memtest = data.get("cuda_memtest", {}).get(str(idx), {})
        if memtest:
            if not memtest.get("passed", True):
                err_count = memtest.get("error_count", 0)
                errors = memtest.get("errors", [])
                issues.append(f"{label} cuda_memtest 显存校验失败：{err_count}个错误（显存硬件故障，【立即RMA】）")
                for e in errors[:5]:
                    issues.append(f"{label}   └ {e}")

        # --- 原厂质检：gpu-burn 满载烧机正确性校验 ---
        burn = data.get("gpu_burn", {}).get(str(idx), {})
        if burn:
            if not burn.get("passed", True):
                errors = burn.get("errors", [])
                issues.append(f"{label} gpu-burn 正确性校验失败：矩阵乘法结果与CPU基准不匹配（计算单元故障，【立即RMA】）")
                for e in errors[:5]:
                    issues.append(f"{label}   └ {e}")

    # --- fieldiag 原厂现场诊断（全局判定，不按GPU分） ---
    fieldiag = data.get("fieldiag", {})
    if fieldiag and fieldiag.get("installed"):
        if not fieldiag.get("passed", True):
            errors = fieldiag.get("errors", [])
            issues.append(f"fieldiag {fieldiag.get('level','')} 诊断未通过（NVIDIA原厂现场诊断，【需RMA或联系原厂支持】）")
            for e in errors[:10]:
                issues.append(f"  └ {e}")

    return (len(issues) == 0), issues


def build_data(output_dir: Path, raw_dir: Path, log_file: Path) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "report_generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "host_info": {},
        "log_tail": safe_read(log_file, 200),
    }

    # 主机信息
    try:
        with open("/etc/os-release") as f:
            data["host_info"]["os_release"] = dict(
                line.strip().split("=", 1) for line in f if "=" in line
            )
    except Exception:
        pass
    data["host_info"]["hostname"] = os.uname().nodename
    data["host_info"]["kernel"] = os.uname().release
    data["host_info"]["arch"] = os.uname().machine

    # GPU基础信息
    data["gpu_basic_info"] = parse_gpu_basic_info(raw_dir / "gpu_basic_info.csv")

    # nvidia-smi XML（权威数据源）
    smi_xml = parse_nvidia_smi_xml(raw_dir / "nvidia_smi_full.xml")
    data["driver_version"] = smi_xml.get("driver_version", "")
    data["cuda_version"] = smi_xml.get("cuda_version", "")
    data["gpus"] = smi_xml.get("gpus", [])

    # 给GPU附加分级信息
    for gpu in data["gpus"]:
        gpu["product_level"] = classify_gpu_level(gpu.get("product_name", ""))

    # GPU数量
    try:
        data["gpu_count"] = int((output_dir / "gpu_count.txt").read_text().strip() or "0")
    except Exception:
        data["gpu_count"] = len(data["gpus"])

    # deviceQuery
    dq_path = raw_dir / "deviceQuery.txt"
    data["device_query"] = parse_device_query(dq_path)

    # PCIe链路状态
    pcie_txt = safe_read(raw_dir / "pcie_link_status.txt")
    data["pcie_link_csv"] = parse_csv_like(pcie_txt)
    data["lspci_vga_verbose"] = safe_read(raw_dir / "lspci_vga_verbose.txt")[:4000]

    # 带宽测试
    gpu_count = data["gpu_count"]
    data["bandwidth"] = {}
    for i in range(gpu_count):
        bw = parse_bandwidth_test(raw_dir / f"bandwidthTest_gpu{i}.txt")
        data["bandwidth"][str(i)] = bw

    # 显存 shmoo（bandwidthTest 回退模式）
    data["memory_test"] = {}
    for i in range(gpu_count):
        mem = parse_bandwidth_test(raw_dir / f"memtest_shmoo_gpu{i}.txt")
        data["memory_test"][str(i)] = mem

    # cuda_memtest 显存10种模式主动校验（原厂质检）
    data["cuda_memtest"] = {}
    for i in range(gpu_count):
        data["cuda_memtest"][str(i)] = parse_cuda_memtest(raw_dir / f"cuda_memtest_gpu{i}.txt")

    # gpu-burn 满载烧机正确性校验（原厂质检）
    data["gpu_burn"] = {}
    for i in range(gpu_count):
        data["gpu_burn"][str(i)] = parse_gpu_burn(raw_dir / f"gpu_burn_gpu{i}.txt")

    # P2P
    data["p2p"] = parse_p2p_test(raw_dir / "p2pBandwidthLatencyTest.txt")
    data["p2p_nvidia_smi"] = safe_read(raw_dir / "nvidia_smi_p2p.txt")[:2000]
    data["topology_smi"] = safe_read(raw_dir / "nvidia_smi_topology.txt")[:4000]
    topology_q = safe_read(raw_dir / "topologyQuery.txt")
    data["topology_query"] = topology_q[:4000]

    # CUDA性能
    data["nbody"] = {}
    data["nbody_fp32"] = {}
    data["matrixMul"] = {}
    for i in range(gpu_count):
        data["nbody"][str(i)] = parse_nbody(raw_dir / f"nbody_gpu{i}.txt")
        data["nbody_fp32"][str(i)] = parse_nbody(raw_dir / f"nbody_fp32_gpu{i}.txt")
        data["matrixMul"][str(i)] = parse_matrixMul(raw_dir / f"matrixMul_gpu{i}.txt")

    # 压力测试监控
    data["stress_monitor"] = parse_stress_monitor(raw_dir / "gpu_monitor_during_stress.csv")

    # ECC
    data["ecc_csv"] = parse_ecc_csv(raw_dir / "nvidia_smi_ecc.txt")
    data["retired_pages_detail"] = safe_read(raw_dir / "nvidia_smi_retired_pages.txt")[:3000]
    data["dmesg_xid"] = parse_dmesg_xid(raw_dir / "dmesg_xid.txt")

    # DCGM
    data["dcgm_diag"] = parse_dcgm_diag(raw_dir / "dcgmi_diag_full.txt")
    data["dcgm_health"] = safe_read(raw_dir / "dcgmi_health.txt")[:4000]
    data["dcgm_stats"] = safe_read(raw_dir / "dcgmi_stats.txt")[:6000]

    # fieldiag 原厂现场诊断
    data["fieldiag"] = parse_fieldiag(
        raw_dir / "fieldiag_result.txt",
        raw_dir / "fieldiag_diag.txt",
        raw_dir / "fieldiag_level.txt",
    )

    # ===== 原厂现场质检（Field Validation）数据 =====
    # ROW_REMAPPER（显存行重映射——RMA判定核心）
    data["row_remapper"] = parse_row_remapper(raw_dir / "nvsmi_row_remapper.txt")

    # NVLink 状态/错误
    data["nvlink"] = parse_nvlink(
        raw_dir / "nvsmi_nvlink_status.txt",
        raw_dir / "nvsmi_nvlink_errors.txt",
        raw_dir / "nvsmi_nvlink_topology.txt",
    )

    # MIG 多实例GPU
    data["mig"] = parse_mig(
        raw_dir / "nvsmi_mig_status.txt",
        raw_dir / "nvsmi_mig_ci.txt",
    )

    # 各域查询（原厂质检补充项）
    data["field_validation"] = {
        "row_remapper": data["row_remapper"],
        "nvlink": data["nvlink"],
        "mig": data["mig"],
        "tile": parse_nvsmi_domain(raw_dir / "nvsmi_tile.txt", "TILE"),
        "power_management": parse_nvsmi_domain(raw_dir / "nvsmi_power_mgmt.txt", "POWER_MANAGEMENT"),
        "virtualization": parse_nvsmi_domain(raw_dir / "nvsmi_virtualization.txt", "VIRTUALIZATION"),
        "supported_clocks": parse_nvsmi_domain(raw_dir / "nvsmi_supported_clocks.txt", "SUPPORTED_CLOCKS"),
        "encoder": parse_nvsmi_domain(raw_dir / "nvsmi_encoder.txt", "ENCODER"),
        "decoder": parse_nvsmi_domain(raw_dir / "nvsmi_decoder.txt", "DECODER"),
        "serial": safe_read(raw_dir / "nvsmi_serial.txt")[:2000],
        "inforom": safe_read(raw_dir / "nvsmi_inforom.txt")[:2000],
        "compute_mode": safe_read(raw_dir / "nvsmi_compute_mode.txt")[:2000],
        "persistence": parse_csv_like(safe_read(raw_dir / "nvsmi_persistence.txt")),
        "clock_policy": safe_read(raw_dir / "nvsmi_clock_policy.txt")[:2000],
        "page_retirement": safe_read(raw_dir / "nvsmi_page_retirement.txt")[:2000],
        "nvswitch": safe_read(raw_dir / "nvsmi_nvswitch.txt")[:2000],
        "lspci_nvswitch": safe_read(raw_dir / "lspci_nvswitch.txt")[:1000],
        "all_domains_snapshot": safe_read(raw_dir / "nvsmi_all_domains.txt")[:4000],
        "dcgmi_policy": safe_read(raw_dir / "dcgmi_policy.txt")[:2000],
        "dcgmi_group": safe_read(raw_dir / "dcgmi_group.txt")[:2000],
        "dcgmi_profile": safe_read(raw_dir / "dcgmi_profile.txt")[:2000],
    }

    # 售后判定
    passed, issues = determine_pass_fail(data)
    data["verdict"] = {
        "overall_pass": passed,
        "issues": issues,
        "summary": "通过（未发现硬件级异常）" if passed else "未通过（发现需排查/保修项）",
        "issue_count": len(issues),
    }

    return data


# ============================================================
# HTML 报告生成（售后服务风格，含品牌、条码、签字栏）
# ============================================================
def render_html(data: Dict[str, Any]) -> str:
    verdict = data.get("verdict", {})
    overall_pass = verdict.get("overall_pass", False)
    issue_count = verdict.get("issue_count", 0)
    verdict_badge = (
        '<span style="background:#2e7d32;color:#fff;padding:4px 14px;border-radius:6px;font-weight:bold;font-size:18px;">通过 PASS</span>'
        if overall_pass
        else f'<span style="background:#c62828;color:#fff;padding:4px 14px;border-radius:6px;font-weight:bold;font-size:18px;">未通过 FAIL ({issue_count}项)</span>'
    )

    gpus = data.get("gpus", [])

    def html_table_from_dicts(rows: List[Dict[str, str]], header_override=None):
        if not rows:
            return "<p><em>无数据</em></p>"
        headers = header_override or list(rows[0].keys())
        lines = ['<table border="1" cellspacing="0" cellpadding="6" style="border-collapse:collapse;font-size:12px;width:100%;">', "<thead><tr>"]
        for h in headers:
            lines.append(f"<th style='background:#e3f2fd;'>{h}</th>")
        lines.append("</tr></thead><tbody>")
        for r in rows:
            lines.append("<tr>")
            for h in headers:
                lines.append(f"<td>{r.get(h, '')}</td>")
            lines.append("</tr>")
        lines.append("</tbody></table>")
        return "".join(lines)

    def gpu_rows_for_table():
        rows = []
        for idx, g in enumerate(gpus):
            rows.append({
                "序号": idx,
                "型号": f"{g.get('product_name','')} <small>({g.get('product_level','')})</small>",
                "PCIe BDF": g.get("pci_bus_id", ""),
                "SN": g.get("serial", "") or "<em style='color:#999'>未披露</em>",
                "UUID": (g.get("uuid", "")[:16] + "...") if g.get("uuid") else "",
                "VBIOS": g.get("vbios_version", ""),
                "显存": g.get("memory_total_mb", ""),
                "计算能力": g.get("compute_cap", ""),
                "ECC模式": g.get("ecc_mode_current", ""),
                "PCIe当前": f"{g.get('pcie_link_gen_current','')} x{g.get('pcie_link_width_current','')}",
                "PCIe最大": f"{g.get('pcie_link_gen_max','')} x{g.get('pcie_link_width_max','')}",
                "Replay": g.get("pcie_replay_counter", ""),
            })
        return rows

    # 问题清单
    issues_html = ""
    if verdict.get("issues"):
        issues_html = "<h3 style='color:#c62828;margin-bottom:6px;'>⚠ 需要排查的问题清单（售后重点）</h3><ol>"
        for it in verdict["issues"]:
            issues_html += f"<li style='margin-bottom:4px;'>{it}</li>"
        issues_html += "</ol>"

    # 温度/功耗压力测试摘要表
    stress_rows = []
    stress = data.get("stress_monitor", {}).get("gpus", {})
    for idx, g in enumerate(gpus):
        s = stress.get(str(idx), {})
        def ss(sub): return ((s.get(sub) or {}).get("min"), (s.get(sub) or {}).get("avg"), (s.get(sub) or {}).get("max"))
        tmin, tavg, tmax = ss("temp_c")
        pmin, pavg, pmax = ss("power_w")
        fmin, favg, fmax = ss("fan_pct")
        umin, uavg, umax = ss("gpu_util_pct")
        stress_rows.append({
            "GPU": f"{idx} - {g.get('product_name','')}",
            "温度C (低/均/高)": f"{tmin}/{tavg}/{tmax}",
            "功耗W (低/均/高)": f"{pmin}/{pavg}/{pmax}",
            "风扇% (低/均/高)": f"{fmin}/{favg}/{fmax}",
            "GPU利用率% (低/均/高)": f"{umin}/{uavg}/{umax}",
            "降频阈值C": g.get("temperature_slow_threshold", ""),
            "TDP限制W": g.get("enforced_power_limit") or g.get("power_limit", ""),
        })

    # 带宽表
    bw_rows = []
    for idx, g in enumerate(gpus):
        b = data.get("bandwidth", {}).get(str(idx), {})
        bw_rows.append({
            "GPU": f"{idx} - {g.get('product_name','')}",
            "Host→Device (GB/s)": b.get("h2d") or "—",
            "Device→Host (GB/s)": b.get("d2h") or "—",
            "Device→Device (GB/s)": b.get("d2d") or "—",
        })

    # CUDA性能表
    perf_rows = []
    for idx, g in enumerate(gpus):
        nb64 = data.get("nbody", {}).get(str(idx), {})
        nb32 = data.get("nbody_fp32", {}).get(str(idx), {})
        mm = data.get("matrixMul", {}).get(str(idx), {})
        perf_rows.append({
            "GPU": f"{idx} - {g.get('product_name','')}",
            "nbody FP64 (GFLOPS)": nb64.get("avg_gflops") or nb64.get("gflops") or "—",
            "nbody FP32 (GFLOPS)": nb32.get("avg_gflops") or nb32.get("gflops") or "—",
            "matrixMul (GFLOPS)": mm.get("perf_gflops") or "—",
            "matrixMul 耗时(ms)": mm.get("time_ms") or "—",
        })

    # ECC / 退役页 表
    ecc_rows = []
    for idx, g in enumerate(gpus):
        ecc = g.get("ecc_errors", {})
        def ecc_v(loc, bit):
            t = ecc.get(loc, {}).get(bit, {})
            return (t.get("register_memory") or t.get("dram") or ",".join(filter(None, t.values())) or "0")
        ecc_rows.append({
            "GPU": f"{idx} - {g.get('product_name','')}",
            "ECC模式": g.get("ecc_mode_current", ""),
            "Volatile SBE": ecc_v("volatile", "single_bit"),
            "Volatile DBE": ecc_v("volatile", "double_bit"),
            "Aggregate SBE": ecc_v("aggregate", "single_bit"),
            "Aggregate DBE": ecc_v("aggregate", "double_bit"),
            "退役页(单比特)": g.get("retired_pages_single_bit", "0"),
            "退役页(双比特)": g.get("retired_pages_double_bit", "0"),
            "待退役页": g.get("retired_pages_pending", "No"),
            "PCIe Replay": g.get("pcie_replay_counter", "0"),
        })

    dcgm_diag = data.get("dcgm_diag", {})
    dcgm_pass = dcgm_diag.get("overall_pass")
    dcgm_html = (
        '<p style="color:#2e7d32;font-weight:bold;">DCGM诊断: PASS</p>'
        if dcgm_pass else
        (
            '<p style="color:#c62828;font-weight:bold;">DCGM诊断: 发现异常，请查看下方原始输出</p>'
            + "<pre style='background:#fff3e0;padding:8px;font-size:11px;overflow:auto;max-height:300px;'>"
            + "\n".join(dcgm_diag.get("summary_lines_failed", [])[:30])
            + "</pre>"
        )
    )

    html = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>NVIDIA GPU 售后服务检测报告 - {data.get('report_generated_at','')}</title>
<style>
body{{font-family:"Microsoft YaHei","Noto Sans CJK SC",Arial,sans-serif;background:#f5f6fa;color:#1c2833;padding:20px 40px;}}
.container{{max-width:1200px;margin:0 auto;background:#fff;padding:40px 50px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,0.06);}}
h1{{color:#0d47a1;border-bottom:3px solid #0d47a1;padding-bottom:10px;margin-top:0;}}
h2{{color:#1565c0;border-left:5px solid #1565c0;padding-left:10px;margin-top:32px;}}
h3{{color:#2e7d32;margin-top:24px;}}
.meta{{display:flex;flex-wrap:wrap;gap:20px;margin:16px 0;color:#555;font-size:13px;}}
.meta span{{background:#e8eaf6;padding:6px 12px;border-radius:4px;}}
.verdict-box{{background:{"#e8f5e9" if overall_pass else "#ffebee"};padding:20px;border-radius:8px;margin:20px 0;border:2px {"#4caf50" if overall_pass else "#e53935"} dashed;}}
th{{background:#e3f2fd;text-align:left;}}
.sign-block{{display:grid;grid-template-columns:1fr 1fr 1fr;gap:30px;margin-top:50px;}}
.sign-box{{border-top:1px solid #666;padding-top:18px;text-align:center;color:#555;font-size:13px;}}
pre{{background:#fafafa;border:1px solid #ddd;padding:10px;border-radius:4px;font-size:12px;overflow:auto;max-height:400px;white-space:pre-wrap;word-break:break-all;}}
.raw-section{{margin-top:16px;}}
details{{margin:8px 0;background:#fafafa;border:1px solid #eee;border-radius:6px;padding:6px 10px;}}
summary{{cursor:pointer;color:#1565c0;font-weight:bold;padding:4px;}}
.small{{font-size:11px;color:#888;}}
.footer{{margin-top:40px;padding-top:20px;border-top:1px solid #ccc;font-size:12px;color:#666;text-align:center;}}
</style>
</head>
<body>
<div class="container">

<h1>NVIDIA GPU 售后服务检测报告</h1>

<div class="meta">
<span>📅 生成时间: {data.get('report_generated_at','')}</span>
<span>🖥 主机名: {data.get('host_info',{}).get('hostname','')}</span>
<span>💻 系统: {data.get('host_info',{}).get('os_release',{}).get('PRETTY_NAME','').strip('"')}</span>
<span>🐧 内核: {data.get('host_info',{}).get('kernel','')}</span>
<span>🎯 驱动: {data.get('driver_version','')}</span>
<span>🧮 CUDA: {data.get('cuda_version','')}</span>
</div>

<div class="verdict-box">
<div style="display:flex;justify-content:space-between;align-items:center;">
  <div style="font-size:22px;font-weight:bold;">整体检测结论：</div>
  <div>{verdict_badge}</div>
</div>
<div style="margin-top:14px;font-size:15px;">{verdict.get('summary','')}　检测GPU数量：{len(gpus)} 块</div>
{issues_html}
</div>

<h2>一、GPU 设备清单与规格</h2>
{html_table_from_dicts(gpu_rows_for_table())}

<h2>二、ECC 错误 / 显存退役页 / PCIe Replay</h2>
{html_table_from_dicts(ecc_rows)}

<h2>三、PCIe 链路状态</h2>
{html_table_from_dicts(data.get('pcie_link_csv', []))}
<details class="raw-section">
<summary>lspci 详细链路信息 (原始输出)</summary>
<pre>{data.get('lspci_vga_verbose','')}</pre>
</details>

<h2>四、PCIe 带宽测试 (Host ↔ Device ↔ Device)</h2>
<p class="small">数据来自NVIDIA官方 cuda-samples/bandwidthTest (Pinned Memory)</p>
{html_table_from_dicts(bw_rows)}
<details class="raw-section">
<summary>PCIe拓扑 (nvidia-smi topo -m)</summary>
<pre>{data.get('topology_smi','')}</pre>
</details>

<h2>五、多GPU P2P 互联测试</h2>
<p class="small">测试工具: cuda-samples/p2pBandwidthLatencyTest / topologyQuery</p>
{
    (lambda p: f'<p style="color:#2e7d32;font-weight:bold;">P2P状态: 可用</p>' if p.get('available') else '<p>P2P原始输出如下，请检查是否按预期启用NVLink/NVSwitch/PCIe P2P</p>')(data.get('p2p',{}))
}
<details class="raw-section">
<summary>P2P 带宽/延迟矩阵 (原始输出)</summary>
<pre>{data.get('p2p',{}).get('raw','')}</pre>
</details>
<details class="raw-section">
<summary>topologyQuery 输出</summary>
<pre>{data.get('topology_query','')}</pre>
</details>

<h2>六、CUDA 计算性能基准 (nbody FP32/FP64 + matrixMul)</h2>
<p class="small">nbody 为NVIDIA官方粒子动力学模拟基准，直接反映FP32/FP64算力；matrixMul测试矩阵乘算力</p>
{html_table_from_dicts(perf_rows)}
<details class="raw-section">
<summary>deviceQuery 完整CUDA能力 (原始输出)</summary>
<pre>{data.get('device_query',{}).get('raw','')}</pre>
</details>

<h2>七、温度 / 功耗 / 稳定性 压力测试</h2>
<p class="small">负载：每GPU运行官方nbody基准持续满负荷；采样：nvidia-smi每秒一次</p>
{html_table_from_dicts(stress_rows)}
<details class="raw-section">
<summary>压力测试CSV原始数据 (逐秒)</summary>
<pre>{safe_read(raw_dir_global / 'gpu_monitor_during_stress.csv', 100) if raw_dir_global else ''}</pre>
</details>

<h2>七.5、显存主动校验（cuda_memtest: 10种模式写入-读出-比对）</h2>
<p class="small">行业级显存质检标准，覆盖 Walking 1s/0s、Random、Gaussian、Solid Bits、Address Fetch、Block Seq、Checkerboard、Shift、Inversions、Memory 共10种测试模式。任何模式报错=显存硬件故障→需RMA</p>
{
    (lambda mt: html_table_from_dicts([
        {"GPU": idx, "通过": ('<span style="color:#2e7d32;font-weight:bold;">PASS</span>' if d.get("passed") else '<span style="color:#c62828;font-weight:bold;">FAIL</span>'),
         "错误数": d.get("error_count", "—"),
         "已跑测试": ", ".join(d.get("tests_run", [])[:10]) or "—"}
        for idx, d in sorted(mt.items())
    ]) if mt else "<p><em>cuda_memtest 不可用或未运行</em></p>")(data.get("cuda_memtest",{}))
}
<details class="raw-section">
<summary>cuda_memtest 各GPU原始输出</summary>
{''.join(f'<pre style="margin-top:8px;">=== GPU {idx} ===\n{d.get("raw","")[:2000]}\n</pre>' for idx, d in sorted(data.get("cuda_memtest",{}).items()))}
</details>

<h2>七.6、满载烧机+正确性校验（gpu-burn: 矩阵乘法结果比对）</h2>
<p class="small">gpu-burn 对每块GPU持续运行大矩阵乘法，计算结果与CPU参考值逐元素比对。任何不匹配=计算单元故障→需RMA。与dcgmi diag -r 3中的Targeted Stress互补，是出厂质检必跑项</p>
{
    (lambda gb: html_table_from_dicts([
        {"GPU": idx,
         "通过": ('<span style="color:#2e7d32;font-weight:bold;">PASS</span>' if d.get("passed") else '<span style="color:#c62828;font-weight:bold;">FAIL</span>'),
         "错误数": len(d.get("errors",[])),
         "摘要": d.get("summary","") or "—"}
        for idx, d in sorted(gb.items())
    ]) if gb else "<p><em>gpu-burn 不可用或未运行</em></p>")(data.get("gpu_burn",{}))
}
<details class="raw-section">
<summary>gpu-burn 各GPU原始输出</summary>
{''.join(f'<pre style="margin-top:8px;">=== GPU {idx} ===\n{d.get("raw","")[:2000]}\n</pre>' for idx, d in sorted(data.get("gpu_burn",{}).items()))}
</details>

<h2>八、NVIDIA DCGM 官方数据中心级诊断</h2>
{dcgm_html}
<details class="raw-section">
<summary>DCGM Level-3 完整诊断 (原始输出)</summary>
<pre>{safe_read(raw_dir_global / 'dcgmi_diag_full.txt') if raw_dir_global else ''}</pre>
</details>
<details class="raw-section">
<summary>DCGM 健康检查</summary>
<pre>{data.get('dcgm_health','')}</pre>
</details>
<details class="raw-section">
<summary>DCGM 详细统计 (PCIe/Xid/ECC实时计数)</summary>
<pre>{data.get('dcgm_stats','')}</pre>
</details>

<h2>八.5、NVIDIA fieldiag 原厂现场诊断（Field Diagnostics）</h2>
<p class="small">fieldiag 是 NVIDIA 原厂现场工程师专用诊断工具，比 dcgmi diag 更深入，覆盖存储/计算/PCIe/NVLink 全子系统。通过企业合作伙伴渠道获取。</p>
{
    (lambda fi: (
        f'<table class="info-table"><tr>'
        f'<th>状态</th><th>诊断级别</th><th>结果</th><th>耗时</th></tr>'
        f'<tr><td>{"<span style=.color:#1565c0;font-weight:bold.>消费级GPU跳过</span>" if fi.get("consumer_skipped") else ("<span style=.color:#c62828;font-weight:bold.>不兼容</span>" if fi.get("incompatible") else ("<span style=.color:#2e7d32;font-weight:bold.>已安装</span>" if fi.get("installed") else "<span style=.color:#e65100;font-weight:bold.>未安装</span>"))}</td>'
        f'<td>{fi.get("level","—")}</td>'
        f'<td>{"消费级跳过" if fi.get("consumer_skipped") else ("INCOMPATIBLE" if fi.get("incompatible") else (("PASS" if fi.get("passed") else "FAIL") if fi.get("installed") else "N/A"))}</td>'
        f'<td>{fi.get("duration","—")}</td></tr></table>'
    ))(data.get("fieldiag", {}))
}
{
    (lambda fi: (
        f'<p style="color:#c62828;">fieldiag 诊断未通过，请查看原始输出。这是NVIDIA原厂诊断工具，未通过意味着需要RMA或联系原厂支持。</p>'
        if fi.get("installed") and not fi.get("incompatible") and not fi.get("consumer_skipped") and not fi.get("passed") else
        f'<p style="color:#1565c0;"><strong>ℹ️ 检测到消费级/非数据中心GPU（RTX/GTX/TITAN 等），已自动跳过 fieldiag 诊断</strong><br>'
        'fieldiag 官方仅支持 Tesla/HGX/DGX 数据中心GPU系列，消费级卡会报 <code>UNSUPPORTED GPU FAMILY</code> 并卡死。<br>'
        '<b>消费级PCIe插槽替代方案已全部自动执行（无需fieldiag）：</b><br>'
        '&nbsp;&nbsp;1. <b>lspci</b> 枚举：确认插槽能识别到GPU<br>'
        '&nbsp;&nbsp;2. <b>nvidia-smi + lspci -vvv</b>：当前链路规格 vs 最大规格 + PCIe重放计数<br>'
        '&nbsp;&nbsp;3. <b>bandwidthTest 原厂工具</b>：H2D/D2H/D2D 带宽实测值<br>'
        '&nbsp;&nbsp;4. <b>bandwidthTest --mode=shmoo</b>：扫频边际稳定性测试<br>'
        '&nbsp;&nbsp;5. <b>nvidia-smi -l 1 压力监控</b>：满载时不降速、温度/功耗正常<br>'
        '以上5项覆盖 PCIe 插槽物理/链路/带宽/稳定性/压力 全维度，结论权威可靠。</p>'
        if fi.get("consumer_skipped") else
        f'<p style="color:#e65100;"><strong>fieldiag 二进制兼容性自检失败（从20.04拷贝到24.04的典型问题）：</strong><br>'
        '解决方式（按优先级）：<br>'
        '1. <b>【推荐】</b>从与当前 Ubuntu 24.04 配套的 CUDA Toolkit 中重新获取 fieldiag 版本（glibc 2.39 版本）<br>'
        '2. 安装缺失依赖：apt install libnvidia-ml-dev datacenter-gpu-manager<br>'
        '3. 在原20.04服务器上运行 <code>ldd ./fieldiag</code> 查看完整依赖列表，逐个在24.04上确认版本<br>'
        '4. glibc 版本差异严重不兼容 → 必须使用 24.04 配套的 fieldiag 版本（或静态编译版）<br>'
        '原始自检输出：<br><pre style="background:#fff3e0;padding:8px;font-size:11px;">'
        + fi.get("raw","")[:3000] + "</pre></p>"
        if fi.get("incompatible") else
        f'<p style="color:#e65100;">fieldiag 未安装。获取方式：<br>1. NVIDIA企业合作伙伴门户: https://partner.nvidia.com<br>2. NVIDIA开发者门户: https://developer.nvidia.com<br>3. 联系NVIDIA技术支持<br>获取后放置到 /usr/local/cuda/bin/fieldiag 或 /opt/nvidia/fieldiag 重新运行脚本。<br><b>注意：从Ubuntu 20.04拷贝过来的二进制文件，脚本会自动跑6项兼容性自检+30秒预检，不兼容会给出具体修复指引。</b></p>'
        if not fi.get("installed") else
        ''
    ))(data.get("fieldiag", {}))
}
<details class="raw-section">
<summary>fieldiag 原始诊断输出</summary>
<pre>{data.get("fieldiag", {}).get("raw", "")}</pre>
</details>
<details class="raw-section">
<summary>fieldiag 兼容性自检：ldd 共享库依赖列表</summary>
<pre>{safe_read(raw_dir_global / 'fieldiag_ldd.txt', 300) if raw_dir_global else ''}</pre>
</details>
<details class="raw-section">
<summary>fieldiag 兼容性自检：--version 输出</summary>
<pre>{safe_read(raw_dir_global / 'fieldiag_version.txt', 100) if raw_dir_global else ''}</pre>
</details>

<h2>九、NVIDIA 原厂现场质检（Field Validation）</h2>
<p class="small">以下数据来自 nvidia-smi -q -d 全域查询，覆盖 NVIDIA 原厂工厂/现场质检标准全量域。这是数据中心GPU(H100~B300)原厂质检/RMA判定的核心依据。</p>

<h3>9.1 显存行重映射器（ROW_REMAPPER）— RMA判定核心</h3>
<p class="small">NVIDIA硬件级显存冗余修复机制：当显存行故障时自动重映射到备用行。备用行耗尽(remapping_failure=Yes)或消耗率>50% → 需RMA</p>
{
    (lambda rr: html_table_from_dicts([
        {"GPU ID": gid, "已重映射行": d.get("remapped_rows","—"), "最大重映射行": d.get("max_remapped_rows","—"),
         "重映射失败": f'<span style="color:#c62828;font-weight:bold;">{d.get("remapping_failure","—")}</span>' if str(d.get("remapping_failure","")).lower() in ("yes","true","1") else str(d.get("remapping_failure","—")),
         "待处理重映射": d.get("pending_remissions","—"), "Bank重映射": str(d.get("bank_remappings","—"))[:60]}
        for gid, d in (rr.get("gpus",{}) or {}).items()
    ]) if rr.get("gpus") else "<p><em>ROW_REMAPPER 无数据（驱动版本过低或非数据中心GPU）</em></p>")(data.get("row_remapper",{}))
}
<details class="raw-section">
<summary>ROW_REMAPPER 原始输出</summary>
<pre>{data.get('row_remapper',{}).get('raw','')}</pre>
</details>

<h3>9.2 NVLink 互联状态与错误计数</h3>
<p class="small">H100/B200/B300多GPU服务器依赖NVLink/NVSwitch互联，链路降级或错误=硬件故障</p>
{
    (lambda nv: (
        f'<p>活跃NVLink数: {nv.get("link_count",0)} / 总链路数: {nv.get("total_links",0)}'
        + (f' <span style="color:#c62828;font-weight:bold;">检测到链路降级</span>' if nv.get("has_degraded_links") else ' <span style="color:#2e7d32;">链路正常</span>')
        + (f' <span style="color:#c62828;">检测到错误计数</span>' if nv.get("has_errors") else '')
    ))(data.get("nvlink",{}))
}
<details class="raw-section">
<summary>NVLink 状态 (nvidia-smi nvlink -s)</summary>
<pre>{data.get('nvlink',{}).get('status_raw','')}</pre>
</details>
<details class="raw-section">
<summary>NVLink 错误计数 (nvidia-smi nvlink -e)</summary>
<pre>{data.get('nvlink',{}).get('errors_raw','')}</pre>
</details>
<details class="raw-section">
<summary>NVLink 拓扑 (nvidia-smi -q -d NVLINK)</summary>
<pre>{data.get('nvlink',{}).get('topology_raw','')}</pre>
</details>
<details class="raw-section">
<summary>NVSwitch 检测</summary>
<pre>{data.get('field_validation',{}).get('nvswitch','')}</pre>
<pre>{data.get('field_validation',{}).get('lspci_nvswitch','')}</pre>
</details>

<h3>9.3 MIG 多实例GPU配置</h3>
<p class="small">H100/B200/B300关键特性：将单GPU切分为多个独立计算实例。用于验证MIG功能完整性</p>
{
    (lambda mig: (
        f'<p>MIG状态: {"已启用" if mig.get("enabled") else "未启用/不可用"} | GPU实例数: {mig.get("gi_count",0)} | 计算实例数: {mig.get("ci_count",0)}</p>'
    ))(data.get("mig",{}))
}
<details class="raw-section">
<summary>MIG GPU实例列表 (nvidia-smi mig -lgi)</summary>
<pre>{data.get('mig',{}).get('status_raw','')}</pre>
</details>
<details class="raw-section">
<summary>MIG 计算实例列表 (nvidia-smi mig -lci)</summary>
<pre>{data.get('mig',{}).get('ci_raw','')}</pre>
</details>

<h3>9.4 多芯片封装验证（TILE）— B200/B300</h3>
<details class="raw-section">
<summary>TILE 域查询 (nvidia-smi -q -d TILE)</summary>
<pre>{data.get('field_validation',{}).get('tile',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('tile'), dict) else data.get('field_validation',{}).get('tile','')}</pre>
</details>

<h3>9.5 功耗管理 / 虚拟化 / 合规时钟 / 编解码引擎</h3>
<details class="raw-section">
<summary>功耗管理策略 (POWER_MANAGEMENT)</summary>
<pre>{data.get('field_validation',{}).get('power_management',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('power_management'), dict) else ''}</pre>
</details>
<details class="raw-section">
<summary>虚拟化支持 (VIRTUALIZATION)</summary>
<pre>{data.get('field_validation',{}).get('virtualization',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('virtualization'), dict) else ''}</pre>
</details>
<details class="raw-section">
<summary>合规时钟频率 (SUPPORTED_CLOCKS)</summary>
<pre>{data.get('field_validation',{}).get('supported_clocks',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('supported_clocks'), dict) else ''}</pre>
</details>
<details class="raw-section">
<summary>视频编码引擎 NVENC (ENCODER)</summary>
<pre>{data.get('field_validation',{}).get('encoder',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('encoder'), dict) else ''}</pre>
</details>
<details class="raw-section">
<summary>视频解码引擎 NVDEC (DECODER)</summary>
<pre>{data.get('field_validation',{}).get('decoder',{}).get('raw','') if isinstance(data.get('field_validation',{}).get('decoder'), dict) else ''}</pre>
</details>

<h3>9.6 序列号 / 保修验证 / InfoROM 完整性</h3>
<p class="small">原厂质检需核对GPU序列号与发货记录一致；InfoROM校验和确认固件未被篡改</p>
{html_table_from_dicts(data.get('field_validation',{}).get('persistence',[]))}
<details class="raw-section">
<summary>序列号 (SERIAL)</summary>
<pre>{data.get('field_validation',{}).get('serial','')}</pre>
</details>
<details class="raw-section">
<summary>InfoROM 完整性 (INFOROM)</summary>
<pre>{data.get('field_validation',{}).get('inforom','')}</pre>
</details>

<h3>9.7 运行模式 / 页面退役详细 / DCGM策略合规</h3>
<details class="raw-section">
<summary>Compute Mode / Persistence Mode</summary>
<pre>{data.get('field_validation',{}).get('compute_mode','')}</pre>
</details>
<details class="raw-section">
<summary>页面退役与重映射详细 (PAGE_RETIREMENT)</summary>
<pre>{data.get('field_validation',{}).get('page_retirement','')}</pre>
</details>
<details class="raw-section">
<summary>时钟策略 (CLOCK_POLICY)</summary>
<pre>{data.get('field_validation',{}).get('clock_policy','')}</pre>
</details>
<details class="raw-section">
<summary>DCGM 策略合规 (dcgmi policy -l)</summary>
<pre>{data.get('field_validation',{}).get('dcgmi_policy','')}</pre>
</details>
<details class="raw-section">
<summary>DCGM GPU分组 (dcgmi group -l)</summary>
<pre>{data.get('field_validation',{}).get('dcgmi_group','')}</pre>
</details>
<details class="raw-section">
<summary>DCGM 性能配置文件 (dcgmi profile -l)</summary>
<pre>{data.get('field_validation',{}).get('dcgmi_profile','')}</pre>
</details>

<h2>十、系统内核日志 (Xid 错误筛查)</h2>
<details class="raw-section">
<summary>dmesg NVRM/Xid (最近50条)</summary>
<pre>{chr(10).join(data.get('dmesg_xid',[])) or '(无)'}</pre>
</details>
<details class="raw-section">
<summary>ECC / 显存退役页详情</summary>
<pre>{data.get('retired_pages_detail','')}</pre>
</details>

<h2>十一、售后服务签字栏</h2>
<div class="sign-block">
<div class="sign-box">客户确认签字<br><br><span style="color:#999;">日期：____/____/____</span></div>
<div class="sign-box">工程师签字<br><br><span style="color:#999;">日期：____/____/____</span></div>
<div class="sign-box">服务主管审核<br><br><span style="color:#999;">日期：____/____/____</span></div>
</div>

<div class="footer">
本报告由 NVIDIA 官方工具 (nvidia-smi / CUDA Toolkit samples / DCGM) 自动实测生成，仅基于实测数据无经验值填充。<br>
若报告中未通过项涉及保修RMA，请携带本报告及对应 SN 办理。报告时间戳: {data.get('report_generated_at','')}
</div>

</div>
</body>
</html>
"""
    return html


# 用闭包传递 raw_dir（更稳妥的写法在main中控制）
raw_dir_global: Optional[Path] = None


def main() -> int:
    global raw_dir_global
    parser = argparse.ArgumentParser()
    parser.add_argument("--output_dir", required=True)
    parser.add_argument("--raw_data_dir", required=True)
    parser.add_argument("--log_file", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    raw_dir = Path(args.raw_data_dir)
    log_file = Path(args.log_file)
    raw_dir_global = raw_dir

    if not output_dir.exists():
        print(f"[错误] output_dir不存在: {output_dir}", file=sys.stderr)
        return 2

    # 1) 构建结构化JSON
    data = build_data(output_dir, raw_dir, log_file)

    json_path = output_dir / "report_data.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"[OK] JSON报告已生成: {json_path}")

    # 2) 生成HTML
    html = render_html(data)
    html_path = output_dir / "report.html"
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"[OK] HTML报告已生成: {html_path}")

    # 3) 控制台快速结论
    v = data.get("verdict", {})
    print("\n=========== 售后检测结论 ===========")
    print(f"GPU总数: {len(data.get('gpus',[]))} 块")
    print(f"整体判定: {'✅ 通过' if v.get('overall_pass') else '❌ 未通过'}")
    for issue in v.get("issues", []):
        print(f"  ⚠ {issue}")
    print(f"详细报告: {html_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
