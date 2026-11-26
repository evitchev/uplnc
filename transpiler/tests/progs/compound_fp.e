/* compound assignment with floating point: double and float targets (a float
   is stored at its own width), an int right side promoted, an int target
   truncating a double result, through a pointer and an array; on i386 a
   discarded x87 result is popped and a used one kept. -> 42 */
var double:gd;
func main()
{
  var double:d;var double:e;var float:f;var float:f2;var int:i;var int:ok;
  var [3]double:da;var [2]float:fa;var *double:dp;var *float:fp;
  ok=0;
  d=1.5;
  d+=2.0;if(d==3.5)++ok;
  d-=0.5;if(d==3.0)++ok;
  d*=2;if(d==6.0)++ok;                      /* an int right side */
  d/=4;if(d==1.5)++ok;
  gd=0.25;gd+=gd;if(gd==0.5)++ok;           /* a global */
  f=1.5;f2=7.25;f+=1.0;                     /* stored as a float: f2 intact */
  if((f==2.5)&&(f2==7.25))++ok;
  f*=f;if(f==6.25)++ok;
  i=5;i+=2.75;if(i==7)++ok;                 /* int target: truncated */
  i*=1.5;if(i==10)++ok;
  da[0]=1.0;da[1]=2.0;da[2]=3.0;
  da[1]+=da[2];if((da[1]==5.0)&&(da[0]==1.0)&&(da[2]==3.0))++ok;
  dp=da;dp+=2;*dp*=10.0;if(da[2]==30.0)++ok;
  fa[0]=1.5;fa[1]=7.25;fp=fa;*fp-=0.25;     /* a float through a pointer */
  if((fa[0]==1.25)&&(fa[1]==7.25))++ok;
  e=(d+=1.0);if((d==2.5)&&(e==2.5))++ok;    /* the value is the stored value */
  e=(f+=0.75)+1.0;if((f==7.0)&&(e==8.0))++ok;
  d=0.0;
  for(i=0;i<20;i++)d+=1.0;                  /* discarded: x87 stack stays empty */
  if(d==20.0)++ok;
  d=0.0;e=0.0;
  for(i=0;i<20;i+=1){d+=0.5;e-=0.5;}
  if((d==10.0)&&(e==0.0-10.0))++ok;
  if(ok==16)return 42;
  return ok;
}
