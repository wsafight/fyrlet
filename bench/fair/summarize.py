import re,sys,statistics as st
f=sys.argv[1]
g={}
for l in open(f):
    if not l.startswith('RESULT'): continue
    tag=re.search(r'-(A|B)\s',l).group(1)
    g.setdefault(tag,[]).append(dict(w=int(re.search(r'writes=\s*(\d+)',l).group(1)),p=float(re.search(r'p95=\s*([\d.]+)',l).group(1)),c=float(re.search(r'appCPU=\s*([\d.]+)',l).group(1)),t=int(re.search(r'throttled=\s*(\d+)',l).group(1)),a=int(re.search(r'anonPeakMiB=(\d+)',l).group(1))))
for k in sorted(g):
    v=g[k]; print(k,len(v),'runs')
    for fld,name in (('w','writes'),('p','p95 ms'),('c','CPU s'),('t','throttled'),('a','anon MiB')):
        xs=[x[fld] for x in v]; print(f'  {name:10} median={st.median(xs):8.1f} mean={st.mean(xs):8.1f} min={min(xs)} max={max(xs)}')
