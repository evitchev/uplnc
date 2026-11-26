/* gdbprog.e: the program gdbtest.e debugs. It must keep c=a+b on line 7,
   where gdbtest.e sets its breakpoint. */

func add(a:int,b:int)
{
  var c:int;
  c=a+b;
  return c;
}

func main()
{
  var x,ch:int;
  printf("hello\n");
  x=add(40,2);
  ch=getchar();          /* typed into the program's own terminal */
  printf("x=%d ch=%c\n",x,ch);
  return x;
}
