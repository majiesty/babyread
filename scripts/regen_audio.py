# -*- coding: utf-8 -*-
"""CI 上用 edge-tts 重新生成全部内置语音（与安卓 APK 内同名同内容）。
   文件名 e 开头 = en-US-JennyNeural（英文），z 开头 = zh-CN-XiaoxiaoNeural（中文）。
   清单 key 即朗读文本。个别条目失败不阻塞构建（网页会回退到系统语音）。"""
import asyncio
import json
import os
import sys

import edge_tts

VOICE = {"e": "en-US-JennyNeural", "z": "zh-CN-XiaoxiaoNeural"}
OUT_DIR = os.path.join("App", "www", "audio")


async def gen(key, fname, sem):
    path = os.path.join(OUT_DIR, fname)
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return 0
    voice = VOICE.get(fname[0], VOICE["e"])
    async with sem:
        for attempt in range(4):
            try:
                await edge_tts.Communicate(key, voice).save(path)
                if os.path.exists(path) and os.path.getsize(path) > 500:
                    return 0
            except Exception:
                await asyncio.sleep(1.5 * (attempt + 1))
    sys.stderr.write("FAIL %s -> %s\n" % (key, fname))
    return 1


async def main():
    with open("audio_manifest.json", encoding="utf-8") as f:
        manifest = json.load(f)
    os.makedirs(OUT_DIR, exist_ok=True)
    sem = asyncio.Semaphore(8)
    results = await asyncio.gather(*[gen(k, v, sem) for k, v in manifest.items()])
    fails = sum(results)
    total = len(manifest)
    ok = total - fails
    print("audio generated: %d/%d ok, %d failed" % (ok, total, fails))
    # 至少成功 90% 才算通过；否则也继续构建（有系统语音兜底），但日志要醒目
    if ok < total * 0.9:
        sys.stderr.write("WARNING: too many audio failures (%d/%d)\n" % (fails, total))


if __name__ == "__main__":
    asyncio.run(main())
