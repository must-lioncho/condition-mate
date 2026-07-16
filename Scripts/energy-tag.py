#!/usr/bin/env python3
# 전략5 에너지 태깅: 파일명은 그대로 두고 ID3 TBPM(에너지 프록시)을 써넣는다.
# (리네임 아님 — 플랜 bgm-plan.json이 오프너를 파일명으로 참조하므로.)
# 값 = 폴더별 순위 스프레드: 제목 키워드 점수가 곡의 순서를 정하고(에너지 낮음→높음),
#      그 순위를 테마 baseline±SPREAD 에 고르게 매핑해 폴더 내부 BPM 을 항상 벌린다.
# 멱등: 재실행하면 TBPM 을 덮어쓴다. 재조정=BASE/SPREAD/키워드 바꿔 재실행.
# heavy_rain(레인리셋 전용 풀)·office(파일명 [NNN] 기태깅)는 제외.
# 사용: python3 scripts/energy-tag.py         # 드라이런(쓰기 없음)
#       python3 scripts/energy-tag.py --apply # 실제 TBPM 기록 (ffmpeg 필요)
import os, re, sys, subprocess, hashlib

ROOT = "bgm"
EXTS = {'.mp3','.m4a','.aac','.wav','.aiff','.aif','.caf'}
SKIP_THEMES = {"office", "heavy_rain"}   # office=이미 태깅, heavy_rain=레인 전용
LO, HI = 74, 150

# 테마별 중심 에너지 (차분 → 격렬)
BASE = {
    "lounge":88, "peace":90, "snow":92, "china":100, "joseon":100, "desert":102,
    "samurai":102, "gold":104, "fantagy":104, "magic":106, "england":108,
    "mongolia":108, "ship":112, "return":116, "last_goal":120, "challenge":124, "steel":126,
    "house":128,   # 파괴 하겠어! — 마감 스퍼트/초집중용 최상위 에너지 (하우스 장르 기본 BPM대)
}
DEFAULT_BASE = 106

STRONG_LOW = ["silent","moonlit","moonlight"," moon","night","snowfall","snowbound","quiet",
              "고요","whisper","pines","hearth","break room","velvet","golden hour","tide",
              "breath","lantern","sakura","still","hidden","forest","garden","crystal cave"]
MILD_LOW = ["village","harbor","rice field","market lane","pavilion","coastal","lounge",
            "moonlit","fields","haven","蔵","edo town","break"]
MILD_HIGH = ["market","town","capital","city","road","journey","voyage","port","bazaar",
             "agora","plaza","court","gathering","harbor lift","anchor","caravan","spice",
             "neon","pulse","concrete"]
STRONG_HIGH = ["storm","forge","forged","steel","engine","industrial","rise","war","siege",
               "fury","dragon","giants","molten","blade","horde","unites","empire","march",
               "great","admiral","general","victory","powder","symphony","iron","flag",
               "fortress","kurultai","temujin","new era","new dynasty","crimson","black flag",
               "return of the fallen","dawn of a new","precision assembly","invisible engine",
               "thunder"]

SPREAD = 22   # 폴더는 baseline±SPREAD 에 걸쳐 분포 (내부 차별화 보장)

def score(title):
    t = title.lower()
    d = 0
    for k in STRONG_HIGH:
        if k in t: d += 16
    for k in MILD_HIGH:
        if k in t: d += 7
    for k in MILD_LOW:
        if k in t: d -= 7
    for k in STRONG_LOW:
        if k in t: d -= 16
    return d

def hkey(name):
    return int(hashlib.sha1(name.encode('utf-8')).hexdigest(), 16)

# 폴더 단위로 순위 스프레드: 키워드 점수가 순서(에너지 낮음→높음)를 정하고
# 동점은 파일명 해시로 분리, 그 순위를 baseline±SPREAD 에 고르게 매핑한다.
# 결과적으로 어떤 폴더든 내부 BPM 이 항상 벌어져 밴드·모드가 다른 곡을 뽑는다.
def bpm_map_for_folder(theme, files):
    base = BASE.get(theme, DEFAULT_BASE)
    ranked = sorted(files, key=lambda f: (score(os.path.splitext(f)[0]), hkey(f)))
    n = len(ranked)
    out = {}
    for r, f in enumerate(ranked):
        if n == 1:
            v = base
        else:
            v = base - SPREAD + (2*SPREAD) * r / (n-1)
        out[f] = max(LO, min(HI, round(v)))
    return out

def write_tbpm(path, bpm):
    tmp = path + ".tagtmp" + os.path.splitext(path)[1]
    r = subprocess.run(["ffmpeg","-y","-v","error","-i",path,"-c","copy",
                        "-write_id3v2","1","-metadata",f"TBPM={bpm}",tmp],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(tmp):
        sys.stderr.write(f"FAIL {path}: {r.stderr}\n")
        if os.path.exists(tmp): os.remove(tmp)
        return False
    os.replace(tmp, path)
    return True

def main():
    apply = "--apply" in sys.argv
    total=0; changed=0
    for theme in sorted(os.listdir(ROOT)):
        tp = os.path.join(ROOT, theme)
        if not os.path.isdir(tp) or theme in SKIP_THEMES: continue
        files = [f for f in sorted(os.listdir(tp)) if os.path.splitext(f)[1].lower() in EXTS]
        if not files: continue
        bmap = bpm_map_for_folder(theme, files)
        vals=[]
        for f in files:
            bpm = bmap[f]
            vals.append((bpm,f)); total+=1
            if apply:
                if write_tbpm(os.path.join(tp,f), bpm): changed+=1
        lo=min(v for v,_ in vals); hi=max(v for v,_ in vals)
        vals.sort()
        sample = ", ".join(f"{v}:{n[:24]}" for v,n in (vals[:1]+vals[len(vals)//2:len(vals)//2+1]+vals[-1:]))
        print(f"[{theme:9}] {len(files):2}곡  BPM {lo}-{hi:<3}  base {BASE.get(theme,DEFAULT_BASE)}  예: {sample}")
    print(f"\n합계 {total}곡" + (f", 쓰기 {changed}곡" if apply else " (드라이런, 쓰기 없음)"))

if __name__=="__main__":
    main()
