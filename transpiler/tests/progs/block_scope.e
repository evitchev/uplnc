/* A plain { } block is a name scope: its locals die at the closing brace and
   their frame slots are reused, as for a control-flow body. Sibling blocks
   reuse names (with other types and sizes), inner blocks see outer names, and
   break/continue/return leave a block with locals. Returns the number of the
   first failing check. -> 42 */
func sumsq(n:int)
{
  var int:i,s;
  s=0;
  i=0;
  while(i<n)
  {
    i=i+1;
    {
      var int:sq;
      sq=i*i;
      if(sq>50)break;
      if(i%2)continue;
      s=s+sq;
    }
  }
  return s;
}
func depth(n:int)
{
  var int:r;
  r=n;
  {
    var int:t;
    t=n*10;
    if(n>0)r=r+depth(n-1);
    if(t!=n*10)return -1000;   /* the recursive call must not clobber t */
  }
  {
    var int:u;
    u=r;
    return u;
  }
}
func main()
{
  var int:keep,s;
  keep=5;
  s=0;
  {
    var int:i;
    i=3;
    s=s+i;
  }
  {
    var int:i;   /* the same name again, in a sibling scope */
    i=4;
    s=s+i;
  }
  if(s!=7)return 1;
  {
    var [4]int:a;   /* a larger object reusing the closed slots */
    a[0]=1;a[1]=2;a[2]=3;a[3]=4;
    s=a[0]+a[1]+a[2]+a[3];
  }
  if(s!=10)return 2;
  if(keep!=5)return 3;   /* block slots never overlap a live outer local */
  {
    var int:outer;
    outer=6;
    {
      var int:inner;
      inner=outer+1;   /* an inner block sees the enclosing block's names */
      s=inner;
    }
    {
      var *char:inner;   /* a sibling may reuse the name with another type */
      inner="abc";
      s=s+inner[2]-'c';
    }
  }
  if(s!=7)return 4;
  var int:after;   /* a later function-level local reuses a closed slot */
  after=8;
  if((keep!=5)||(after!=8))return 5;
  if(sumsq(10)!=56)return 6;   /* 4+16+36: odd squares skipped, stop at 64 */
  switch(keep)
  {
    case 5:
    {
      var int:c;
      c=keep*2;
      s=c;
      break;
    }
    default:
    s=0;
  }
  if(s!=10)return 7;
  if(depth(3)!=6)return 8;   /* 3+2+1+0 */
  {
    var int:k,acc;
    acc=0;
    for(k=0;k<5;k++)acc=acc+k;
    s=acc;
  }
  {
    var int:k,acc;
    acc=1;
    for(k=1;k<5;k++)acc=acc*k;
    s=s+acc;
  }
  if(s!=34)return 9;   /* 10 + 24 */
  return 42;
}
