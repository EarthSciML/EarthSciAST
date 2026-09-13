import re,sys
def load(p):
    out={}
    for line in open(p,errors='replace'):
        line=re.sub(r'^\S+Z ','',line.rstrip('\n')); line=re.sub(r'\x1b\[[0-9;]*m','',line)
        m=re.match(r'^(\s\s)(\S.*?)\s*\|\s+[\d\s]*?([\dhms.]+)\s*$',line)
        if not m or len(m.group(1))!=2: continue
        mm=re.match(r'^(?:(\d+)h)?(?:(\d+)m)?([\d.]+)s$',m.group(3))
        if not mm: continue
        h,mi,s=mm.groups(); out[m.group(2)]=out.get(m.group(2),0)+(int(h or 0)*3600+int(mi or 0)*60+float(s))
    return out
d={n:load(f'{n}.log') for n in sys.argv[1:]}
for n,v in d.items(): print(f"{n}: {len(v)} testsets, {sum(v.values())/60:.1f} min")
# biggest 1.13-vs-1.10 blowups, restricted to shard 1
a,b=d.get('113s1',{}),d.get('110s1',{})
print("\n1.13 shard-1 testsets most inflated vs the same testset on 1.10 shard 1:")
rows=sorted(((a[k]-b.get(k,0),k,b.get(k,0),a[k]) for k in a if k in b),reverse=True)[:8]
for dlt,k,x,y in rows: print(f"  {k[:60]:<62} 1.10={x:6.1f}s  1.13={y:6.1f}s  (+{dlt:.0f}s)")
