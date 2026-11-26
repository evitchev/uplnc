/* values that are computed and thrown away, and assignments whose values are
   used. On i386 every FP value lives on the 8-slot x87 stack, so a statement
   that discards one (d++, a double-returning call, a comma's left side) must
   pop it, and an FP assignment used as a value must keep it. -> 42 */
var double:gd;
func next():double
{
  gd=gd+1.0;
  return gd;
}
func main()
{
  var double:d;var double:x;var double:y;var float:f;var float:f2;var int:i;var int:ok;
  var [2]float:fa;var *float:fp;
  ok=0;
  d=0.0;for(i=0;i<20;i++)d++;if(d==20.0)++ok;
  d=0.0;for(i=0;i<20;i++)++d;if(d==20.0)++ok;
  d=20.0;for(i=0;i<20;i++)d--;if(d==0.0)++ok;
  gd=0.0;for(i=0;i<20;i++)next();if(gd==20.0)++ok;
  for(i=0;i<20;i++){d+1.0;d;}               /* values nobody uses */
  if(d+1.0==1.0)++ok;
  d=0.0;for(i=0;i<20;i++)x=d+1.0,d++;if((d==20.0)&&(x==20.0))++ok;
  for(d=0.0;d<20.0;d++)x=d;if(x==19.0)++ok; /* a for clause */
  x=(d=1.5);if((x==1.5)&&(d==1.5))++ok;     /* an assignment's value, kept */
  x=(d=2.5)+(y=0.5);if((x==3.0)&&(y==0.5))++ok;
  d=1.0;x=d++;y=++d;if((x==1.0)&&(y==3.0))++ok;
  f=1.5;f2=7.25;f++;if((f==2.5)&&(f2==7.25))++ok;  /* float ++ stays 4 bytes */
  f--;--f;if(f==0.5)++ok;
  fa[0]=1.5;fa[1]=7.25;fp=fa;(*fp)++;
  if((fa[0]==2.5)&&(fa[1]==7.25))++ok;
  x=(f=1.5)+1.0;if(x==2.5)++ok;             /* a float assignment's value */
  x=f++ +1.0;if((x==2.5)&&(f==2.5))++ok;
  if(ok==15)return 42;
  return ok;
}
