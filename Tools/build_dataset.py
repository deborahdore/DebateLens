"""Convert ElecDeb60to20 annotations into the JSON bundle used by the DebateLens iOS app.

usage: python build_dataset.py <ElecDeb60to20/data/annotations> <DebateLens/Resources/Data>
"""
import ast, csv, json, os, re, sys
from collections import defaultdict

src, out = sys.argv[1], sys.argv[2]
os.makedirs(f"{out}/debates", exist_ok=True)

# (speaker label, year) -> canonical politician. Moderators/panelists are not listed and are shown as such.
CANDIDATES = {
    ("KENNEDY", 1960): ("John F. Kennedy", "D"), ("NIXON", 1960): ("Richard Nixon", "R"),
    ("CARTER", 1976): ("Jimmy Carter", "D"), ("FORD", 1976): ("Gerald Ford", "R"),
    ("MONDALE", 1976): ("Walter Mondale", "D"), ("DOLE", 1976): ("Bob Dole", "R"),
    ("REAGAN", 1980): ("Ronald Reagan", "R"), ("CARTER", 1980): ("Jimmy Carter", "D"), ("ANDERSON", 1980): ("John B. Anderson", "I"),
    ("REAGAN", 1984): ("Ronald Reagan", "R"), ("MONDALE", 1984): ("Walter Mondale", "D"),
    ("BUSH", 1984): ("George H. W. Bush", "R"), ("FERRARO", 1984): ("Geraldine Ferraro", "D"),
    ("BUSH", 1988): ("George H. W. Bush", "R"), ("DUKAKIS", 1988): ("Michael Dukakis", "D"),
    ("QUAYLE", 1988): ("Dan Quayle", "R"), ("BENTSEN", 1988): ("Lloyd Bentsen", "D"),
    ("BUSH", 1992): ("George H. W. Bush", "R"), ("CLINTON", 1992): ("Bill Clinton", "D"), ("PEROT", 1992): ("Ross Perot", "I"),
    ("QUAYLE", 1992): ("Dan Quayle", "R"), ("GORE", 1992): ("Al Gore", "D"), ("STOCKDALE", 1992): ("James Stockdale", "I"),
    ("CLINTON", 1996): ("Bill Clinton", "D"), ("DOLE", 1996): ("Bob Dole", "R"),
    ("GORE", 1996): ("Al Gore", "D"), ("KEMP", 1996): ("Jack Kemp", "R"),
    ("BUSH", 2000): ("George W. Bush", "R"), ("GORE", 2000): ("Al Gore", "D"),
    ("CHENEY", 2000): ("Dick Cheney", "R"), ("LIEBERMAN", 2000): ("Joe Lieberman", "D"),
    ("BUSH", 2004): ("George W. Bush", "R"), ("KERRY", 2004): ("John Kerry", "D"),
    ("CHENEY", 2004): ("Dick Cheney", "R"), ("EDWARDS", 2004): ("John Edwards", "D"),
    ("OBAMA", 2008): ("Barack Obama", "D"), ("MCCAIN", 2008): ("John McCain", "R"),
    ("BIDEN", 2008): ("Joe Biden", "D"), ("PALIN", 2008): ("Sarah Palin", "R"),
    ("OBAMA", 2012): ("Barack Obama", "D"), ("ROMNEY", 2012): ("Mitt Romney", "R"), ("ROMNEHY", 2012): ("Mitt Romney", "R"),
    ("BIDEN", 2012): ("Joe Biden", "D"), ("RYAN", 2012): ("Paul Ryan", "R"),
    ("CLINTON", 2016): ("Hillary Clinton", "D"), ("TRUMP", 2016): ("Donald Trump", "R"),
    ("PENCE", 2016): ("Mike Pence", "R"), ("KAINE", 2016): ("Tim Kaine", "D"),
    ("TRUMP", 2020): ("Donald Trump", "R"), ("BIDEN", 2020): ("Joe Biden", "D"),
    ("PENCE", 2020): ("Mike Pence", "R"), ("HARRIS", 2020): ("Kamala Harris", "D"),
    ("TRUMP", 2024): ("Donald Trump", "R"), ("BIDEN", 2024): ("Joe Biden", "D"), ("HARRIS", 2024): ("Kamala Harris", "D"),
}

FALLACY_NAMES = {"AdHominem": "Ad Hominem", "AppealtoEmotion": "Appeal to Emotion", "AppealtoAuthority": "Appeal to Authority",
                 "FalseCause": "False Cause", "Slipperyslope": "Slippery Slope", "Slogans": "Slogans"}

def slug(name): return re.sub(r"[^a-z]+", "-", name.lower()).strip("-")

# --- fallacies grouped by debate --------------------------------------------------------------
fallacies_by_debate = defaultdict(list)
with open(f"{src}/fallacies/fallacies_with_span.csv") as f:
    for i, r in enumerate(csv.DictReader(f)):
        try: s, e = ast.literal_eval(r["text_span"])
        except Exception: s, e = None, None
        fallacies_by_debate[r["debate_id"]].append(dict(
            id=f"F{i}", category=FALLACY_NAMES.get(r["fallacy"], r["fallacy"]), subcategory=r["subcategory"].strip(),
            text=r["text"].strip(), componentId=r["component_id"] or None, start=s, end=e))

# --- debates ------------------------------------------------------------------------------------
index = {"debates": [], "politicians": {}}
pol_stats = defaultdict(lambda: dict(debates=set(), claims=0, premises=0, fallacies=0, years=set()))
debate_files = sorted(os.listdir(f"{src}/relations"), key=lambda x: int(x.split("_")[0]))

for fn in debate_files:
    did = fn[:-4]; num, year = did.split("_"); year = int(year)
    text = open(f"{src}/txt/{did}.txt").read()

    # turns: "SPEAKER: text" lines, with absolute char offsets
    turns, pos = [], 0
    for line in text.split("\n"):
        m = re.match(r"([A-Z][A-Z .'-]+?):\s", line)
        if m and line.strip():
            label = m.group(1)
            cand = CANDIDATES.get((label, year))
            turns.append(dict(id=len(turns), speaker=label, politician=slug(cand[0]) if cand else None,
                              start=pos + m.end(), end=pos + len(line), text=line[m.end():]))
        pos += len(line) + 1

    def turn_for(offset):
        for t in turns:
            if t["start"] <= offset <= t["end"]: return t
        return None

    # components + relations from brat .ann
    comps, rels = {}, []
    for line in open(f"{src}/relations/{did}.ann"):
        p = line.rstrip("\n").split("\t")
        if not p or not p[0]: continue
        if p[0].startswith("T"):
            kind, *span = p[1].split(" ", 1); segs = [tuple(map(int, s.split())) for s in span[0].split(";")]
            t = turn_for(segs[0][0])
            comps[p[0]] = dict(id=p[0], type=kind, text=p[2] if len(p) > 2 else "", turnId=t["id"] if t else None,
                               speaker=t["speaker"] if t else "", politician=t["politician"] if t else None,
                               segments=[dict(start=s, end=e) for s, e in segs], fallacies=[])
        elif p[0].startswith("R"):
            kind, a, b = p[1].split(); rels.append(dict(id=p[0], type=kind, source=a[5:], target=b[5:]))
    rels = [r for r in rels if r["source"] in comps and r["target"] in comps]

    fals = fallacies_by_debate.get(did, [])
    for f in fals:
        t = turn_for(f["start"]) if f["start"] is not None else None
        f["turnId"] = t["id"] if t else None; f["speaker"] = t["speaker"] if t else ""; f["politician"] = t["politician"] if t else None
        if f["componentId"] in comps: comps[f["componentId"]]["fallacies"].append(f["id"])

    # keep only turns; sort components by offset
    complist = sorted(comps.values(), key=lambda c: c["segments"][0]["start"])
    for c in complist:
        c["supports"] = [r["target"] for r in rels if r["source"] == c["id"] and r["type"] == "Support"]
        c["attacks"] = [r["target"] for r in rels if r["source"] == c["id"] and r["type"] == "Attack"]
        c["supportedBy"] = [r["source"] for r in rels if r["target"] == c["id"] and r["type"] == "Support"]
        c["attackedBy"] = [r["source"] for r in rels if r["target"] == c["id"] and r["type"] == "Attack"]
        c["equivalentTo"] = sorted({r["source"] if r["target"] == c["id"] else r["target"] for r in rels
                                    if r["type"] == "Equivalent" and c["id"] in (r["source"], r["target"])})

    participants = sorted({t["politician"] for t in turns if t["politician"]})
    date = None
    for a in os.listdir(f"{src}/arguments/{did}") if os.path.isdir(f"{src}/arguments/{did}") else []:
        with open(f"{src}/arguments/{did}/{a}") as fh:
            row = next(csv.DictReader(fh), None)
            if row and row.get("date"): date = row["date"]; break
    VP = {("MONDALE",1976),("DOLE",1976),("BUSH",1984),("FERRARO",1984),("QUAYLE",1988),("BENTSEN",1988),("QUAYLE",1992),("GORE",1992),
          ("STOCKDALE",1992),("GORE",1996),("KEMP",1996),("CHENEY",2000),("LIEBERMAN",2000),("CHENEY",2004),("EDWARDS",2004),
          ("BIDEN",2008),("PALIN",2008),("BIDEN",2012),("RYAN",2012),("PENCE",2016),("KAINE",2016),("PENCE",2020),("HARRIS",2020)}
    kind = "Vice-presidential" if any((t["speaker"], year) in VP for t in turns) else "Presidential"
    title = f"{year} {kind} debate"
    if date: title += f" · {date}"

    debate = dict(id=did, year=year, date=date, kind=kind, title=title, participants=participants,
                  turns=turns, components=complist, relations=rels, fallacies=fals)
    json.dump(debate, open(f"{out}/debates/{did}.json", "w"), ensure_ascii=False, separators=(",", ":"))

    nclaims = sum(c["type"] == "Claim" for c in complist); nprem = len(complist) - nclaims
    index["debates"].append(dict(id=did, year=year, date=date, kind=kind, title=title, participants=participants,
                                 turnCount=len(turns), claims=nclaims, premises=nprem, relations=len(rels), fallacies=len(fals)))
    for p in participants:
        st = pol_stats[p]; st["debates"].add(did); st["years"].add(year)
        st["claims"] += sum(c["type"] == "Claim" and c["politician"] == p for c in complist)
        st["premises"] += sum(c["type"] == "Premise" and c["politician"] == p for c in complist)
        st["fallacies"] += sum(f["politician"] == p for f in fals)
    print(did, len(turns), "turns", len(complist), "components", len(rels), "relations", len(fals), "fallacies")

for (label, year), (name, party) in CANDIDATES.items():
    s = slug(name)
    if s not in pol_stats: continue
    st = pol_stats[s]
    index["politicians"][s] = dict(id=s, name=name, party=party, labels=sorted({l for (l, y), (n, _) in CANDIDATES.items() if n == name}),
                                   debates=sorted(st["debates"], key=lambda d: int(d.split("_")[0])), years=sorted(st["years"]),
                                   claims=st["claims"], premises=st["premises"], fallacies=st["fallacies"])
json.dump(index, open(f"{out}/index.json", "w"), ensure_ascii=False, separators=(",", ":"), indent=None)
print(len(index["debates"]), "debates,", len(index["politicians"]), "politicians")
