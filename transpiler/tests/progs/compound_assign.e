/* compound assignment (+= -= *= /= %= &= |= ^= <<= >>=) on integer and
   pointer targets: locals, globals, array elements, struct fields, through a
   pointer and inside a method; the target is evaluated once; the result is
   the stored value; narrow and unsigned targets keep their own rules. -> 42 */
struct pt{int x; int y; func bump;};
method pt.bump(d:int){x+=d;return x;}
var int:g;
var [4]int:ga;
var int:calls;
func cell(a:*int):*int
{
  ++calls;
  return a;
}
func main()
{
  var int:a;var int:b;var int:i;var int:ok;
  var [5]int:arr;var *int:p;var pt:s;var *pt:sp;
  var char:c;var unsigned char:uc;var unsigned:u;
  ok=0;
  a=10;
  a+=5;if(a==15)++ok;
  a-=3;if(a==12)++ok;
  a*=4;if(a==48)++ok;
  a/=5;if(a==9)++ok;
  a%=4;if(a==1)++ok;
  a=12;a&=10;if(a==8)++ok;
  a|=3;if(a==11)++ok;
  a^=6;if(a==13)++ok;
  a<<=2;if(a==52)++ok;
  a>>=3;if(a==6)++ok;
  a=0-20;a>>=2;if(a==0-5)++ok;              /* signed: arithmetic shift */
  a=7;a-=-1;a+=-2;if(a==6)++ok;             /* a unary minus after the operator */
  g=1;g+=41;if(g==42)++ok;                  /* a global */
  for(i=0;i<5;i+=1)arr[i]=i;
  i=1;arr[i++]+=10;                         /* the index is evaluated once */
  if((arr[1]==11)&&(i==2))++ok;
  ga[3]=5;ga[3]*=ga[3];if(ga[3]==25)++ok;
  calls=0;*cell(&a)+=4;                     /* a call in the target: once */
  if((a==10)&&(calls==1))++ok;
  p=arr;p+=2;if(*p==2)++ok;                 /* pointer += scales by the element */
  p-=1;if(*p==11)++ok;
  *p-=1;if(arr[1]==10)++ok;                 /* through the pointer */
  s.x=1;s.y=2;s.x+=s.y;if(s.x==3)++ok;      /* struct fields */
  sp=&s;sp->y*=7;if(s.y==14)++ok;
  if(s.bump(4)==7)++ok;                     /* a field inside a method */
  b=(a+=1);if((a==11)&&(b==11))++ok;        /* the value is the stored value */
  a=1;b=2;a+=b+=3;if((a==6)&&(b==5))++ok;   /* right to left */
  a=2;a*=3+4;if(a==14)++ok;                 /* the whole right side first */
  a=100;b=0;while((a-=30)>0)++b;if(b==3)++ok;
  c=100;c+=100;if(c==0-56)++ok;             /* char wraps, signed */
  uc=200;uc+=100;if(uc==44)++ok;            /* unsigned char wraps */
  u=0-1;u>>=1;a=u;if(a>0)++ok;              /* unsigned: logical shift */
  u=0-2;u/=2;if(u>1000)++ok;                /* unsigned division */
  a=5;a+=a;if(a==10)++ok;
  a=3;a=-1;if(a==0-1)++ok;                  /* `=-` is still = then minus */
  if(ok==32)return 42;
  return ok;
}
