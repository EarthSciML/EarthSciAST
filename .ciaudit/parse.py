import re,sys,collections
def load(p):
    out={}
    for line in open(p,errors='replace'):
        line=re.sub(r'^\S+Z ','',line.rstrip('\n'))
        line=re.sub(r'\x1b\[[0-9;]*m','',line)
        m=re.match(r'^(\s\s)(\S.*?)\s*\|\s+[\d\s]*?([\dhms.]+)\s*$',line)
        if not m: continue
        indent,name,t=m.groups()
        if len(indent)!=2: continue
        sec=0.0
        mm=re.match(r'^(?:(\d+)h)?(?:(\d+)m)?([\d.]+)s$',t)
        if not mm: continue
        h,mi,s=mm.groups()
        sec=(int(h or 0))*3600+(int(mi or 0))*60+float(s)
        out[name]=out.get(name,0)+sec
    return out
a={v:load(f'fail{v}.log') for v in ('110','111','112')}
keys=set().union(*[set(d) for d in a.values()])
rows=sorted(keys,key=lambda k:-max(a[v].get(k,0) for v in a))
tot={v:sum(a[v].values()) for v in a}
print("TOTALS(depth1 sum):",{v:round(tot[v]/60,1) for v in tot}, "counts",{v:len(a[v]) for v in a})
print(f"{'testset':<70}{'1.10':>9}{'1.11':>9}{'1.12':>9}")
cum=0
for k in rows[:45]:
    print(f"{k[:69]:<70}{a['110'].get(k,0):>9.1f}{a['111'].get(k,0):>9.1f}{a['112'].get(k,0):>9.1f}")
