from PIL import Image, ImageDraw, ImageFilter
S=4; W=1024*S
def c(h): return tuple(int(h[i:i+2],16) for i in (1,3,5))
img=Image.new('RGB',(W,W))
# fundo: gradiente vertical
top=c('#161C25'); bot=c('#0A0D12')
px=img.load()
d=ImageDraw.Draw(img)
for y in range(W):
    t=y/(W-1); col=tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3))
    d.line([(0,y),(W,y)],fill=col)
# brilho verde-agua atras da pulseira
glow=Image.new('RGB',(W,W),(0,0,0)); g=ImageDraw.Draw(glow)
g.ellipse([W*0.22,W*0.24,W*0.78,W*0.76],fill=(22,90,78))
glow=glow.filter(ImageFilter.GaussianBlur(W*0.09))
img=Image.blend(img,Image.eval(glow,lambda v:v),0.0)
img=Image.composite(img,img,Image.new('L',(W,W),255))
from PIL import ImageChops
img=ImageChops.add(img,glow)
d=ImageDraw.Draw(img)
cx=W/2
# pulseiras (cima/baixo)
sw_t=250*S; sw_b=300*S
strap=c('#20252D')
d.polygon([(cx-sw_b/2,W*0.30),(cx+sw_b/2,W*0.30),(cx+sw_t/2,-10),(cx-sw_t/2,-10)],fill=strap)
d.polygon([(cx-sw_b/2,W*0.70),(cx+sw_b/2,W*0.70),(cx+sw_t/2,W+10),(cx-sw_t/2,W+10)],fill=strap)
# furinhos da pulseira de baixo
for i in range(3):
    y=W*0.80+i*48*S
    d.ellipse([cx-11*S,y-11*S,cx+11*S,y+11*S],fill=c('#12161C'))
# corpo
bw=380*S; bh=580*S; r=118*S
x0=cx-bw/2; y0=W/2-bh/2
d.rounded_rectangle([x0-6*S,y0-6*S,x0+bw+6*S,y0+bh+6*S],radius=r+6*S,fill=c('#3A414C'))
d.rounded_rectangle([x0,y0,x0+bw,y0+bh],radius=r,fill=c('#1B1F25'))
# botao lateral
d.rounded_rectangle([x0+bw+4*S,W/2-70*S,x0+bw+20*S,W/2+10*S],radius=8*S,fill=c('#3A414C'))
# tela
ins=30*S
d.rounded_rectangle([x0+ins,y0+ins,x0+bw-ins,y0+bh-ins],radius=r-ins,fill=c('#07090C'))
# linha de batimento (icone "Today": M3 12h4l3 7 4-14 3 7h4), escalada para a tela
pts=[(3,12),(7,12),(10,19),(14,5),(17,12),(21,12)]
sx=(bw-2*ins-70*S)/18; sy=sx*1.15
ox=x0+ins+35*S - 3*sx; oy=W/2 - 12*sy
P=[(ox+x*sx, oy+y*sy) for x,y in pts]
teal=c('#3DD6B5')
# brilho da linha
gl=Image.new('RGB',(W,W),(0,0,0)); gd=ImageDraw.Draw(gl)
gd.line(P,fill=(30,140,118),width=60*S,joint='curve')
gl=gl.filter(ImageFilter.GaussianBlur(26*S))
img=ImageChops.add(img,gl)
d=ImageDraw.Draw(img)
w=30*S
d.line(P,fill=teal,width=w,joint='curve')
for p in (P[0],P[-1]):
    d.ellipse([p[0]-w/2,p[1]-w/2,p[0]+w/2,p[1]+w/2],fill=teal)
for p in P[1:-1]:
    d.ellipse([p[0]-w/2,p[1]-w/2,p[0]+w/2,p[1]+w/2],fill=teal)
out=img.resize((1024,1024),Image.LANCZOS)
out.save('AppIcon-1024.png')
# preview com mascara arredondada do iOS
m=Image.new('L',(1024,1024),0); ImageDraw.Draw(m).rounded_rectangle([0,0,1023,1023],radius=228,fill=255)
pv=Image.new('RGB',(1024,1024),(245,245,245)); pv.paste(out,(0,0),m)
pv.resize((512,512),Image.LANCZOS).save('preview.png')
