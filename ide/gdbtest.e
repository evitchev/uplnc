/* gdbtest.e: gdb.e's proof. First, on every backend and without gdb, a
   session fed by hand through a pipe: lines split across reads, results
   found by token out of order, a queue that grows and compacts without
   losing order, and the end of the stream; and waits that keep to their
   time, by the clock, whether records pour in or a record trickles in a
   byte at a time. Then, given PROGRAM, a real gdb
   session. It debugs gdbprog.e (built
   with -g): a breakpoint by file:line, a run that stops there with the
   frame and arguments, the output the program printed read from its own
   terminal, an expression and the stack, a continue with input typed into
   that terminal, the exit code, an error for a bad command, the console
   text gdb queued meanwhile, output long enough to split lines across
   reads, and a clean exit; before all that, sessions that fail to start
   (no such gdb, no such program). On failure it prints the
   number of the first failing check and exits 1; success is exit 42.

   Usage: gdbtest [PROGRAM [GDB]]   (PROGRAM built from ide/gdbprog.e)
   Build: perl src/langdrv.pl -march=ARCH -o gdbtest ide/gdbtest.e
          ide/gdb.e ide/mi.e ide/tshim.c */

#include "gdb.he"

func exit(c:int);
func strstr(h:*char,n:*char):*char;
func gdlen(s:*char);
func sprintf(b:*char,f:*char,...);
func tsh_pipe(fds:*int);
func tsh_write(fd:int,buf:*char,n:int);
func tsh_close(fd:int);
func tsh_child(argv:**char,fds:*int);
func tsh_wait(pid:int,hang:int);
func tsh_kill(pid:int,sig:int);
func tsh_clock();

var gtn:int;
var gtout:[8192]char;    /* everything the program printed */
var gtlen:int;

func ck(ok:int)
{
  gtn++;
  if(!ok)
  {
    printf("gdbtest: check %d failed\n",gtn);
    exit(1);
  }
  return 0;
}

func gteq(a:*char,b:*char)
{
  var i:int;
  if(!a)return 0;
  i=0;
  while(a[i]&&(a[i]==b[i]))i++;
  return a[i]==b[i];
}

/* read the program's terminal until want shows up, for up to 10 s */
func gtsee(g:*sgdb,want:*char)
{
  var n,t0:int;
  t0=tsh_clock();
  while(tsh_clock()-t0<10000)
  {
    gtout[gtlen]=0;
    if(strstr(gtout,want))return 1;
    n=g->ptyread(gtout+gtlen,8191-gtlen,100);
    if(n>0)gtlen=gtlen+n;
  }
  gtout[gtlen]=0;
  return strstr(gtout,want)!=0;
}

/* write s into the session's stream, then queue what arrived */
func gtfeed(g:*sgdb,w:int,s:*char)
{
  tsh_write(w,s,gdlen(s));
  return g->poll(1000);
}

/* the session-free half: line assembly and the queue */
func gtqueue()
{
  var g:sgdb;
  var [2]int:fds;
  var [32]char:b;
  var r:*mirec;
  var i,n:int;
  ck(g.init()==0);
  ck(tsh_pipe(fds)==0);
  g.out=fds[0];
  ck(gtfeed(&g,fds[1],"1^do")==0);          /* half a line: nothing yet */
  ck(gtfeed(&g,fds[1],"ne,value=\"2\"\n2^done,value=\"5\"\n~\"x")==2);
  ck(gtfeed(&g,fds[1],"y\"\n")==1);
  r=g.find(MR_RESULT,0,2);                 /* the later result, by token */
  ck(r!=0);
  ck(r->token==2);
  ck(gteq(r->str("value"),"5"));
  r->done();
  r=g.take();                              /* the rest keep their order */
  ck(r->token==1);
  ck(gteq(r->str("value"),"2"));
  r->done();
  r=g.take();
  ck(r->type==MR_CONSOLE);
  ck(gteq(r->text,"xy"));
  r->done();
  ck(g.take()==0);
  /* 20 records, 5 taken, 30 more: the queue grows, then compacts */
  for(i=0;i<20;i++)
  {
    sprintf(b,"%d^done\n",i);
    gtfeed(&g,fds[1],b);
  }
  for(i=0;i<5;i++)
  {
    r=g.take();
    ck(r->token==i);
    r->done();
  }
  for(i=20;i<50;i++)
  {
    sprintf(b,"%d^done\n",i);
    gtfeed(&g,fds[1],b);
  }
  r=g.find(MR_RESULT,0,30);
  ck(r->token==30);
  r->done();
  n=5;
  r=g.take();
  while(r)
  {
    if(n==30)n++;
    ck(r->token==n);
    n++;
    r->done();
    r=g.take();
  }
  ck(n==50);
  /* the end of the stream: a last line without its newline still counts */
  gtfeed(&g,fds[1],"7^exit");
  tsh_close(fds[1]);
  ck(g.poll(1000)==0-1);
  ck(g.dead);
  r=g.take();
  ck(r->token==7);
  ck(gteq(r->cls,"exit"));
  r->done();
  ck(g.poll(0)==0-1);
  ck(g.stop()==0-1);                       /* no gdb was ever started */
  return 0;
}

/* a session reading what the shell script prints, standing in for gdb */
func gtfeeder(g:*sgdb,script:*char,fds:*int)
{
  var [4]*char:av;
  var pid:int;
  av[0]="sh";
  av[1]="-c";
  av[2]=script;
  av[3]=0;
  g->init();
  pid=tsh_child(av,fds);
  g->out=fds[1];
  return pid;
}

/* waits keep to their time by the clock, not by what arrives */
func gtclock()
{
  var g:sgdb;
  var [2]int:fds;
  var r:*mirec;
  var pid,t0,e:int;
  /* a record every 10 ms, never the one awaited: 300 ms is 300 ms */
  pid=gtfeeder(&g,"i=0; while [ $i -lt 1000 ]; do echo '=thread-created,id=\"1\"'; sleep 0.01; i=$((i+1)); done",fds);
  ck(pid>0);
  t0=tsh_clock();
  r=g.wait(MR_EXEC,"stopped",300);
  e=tsh_clock()-t0;
  ck(r==0);
  ck(e>=300);
  ck(e<2000);
  ck(g.qn>g.qh);                 /* the chatter itself was queued */
  tsh_kill(pid,9);
  tsh_wait(pid,1);
  tsh_close(fds[0]);
  g.stop();
  /* the awaited record a byte every 10 ms: found well inside 1.5 s */
  pid=gtfeeder(&g,"s='*stopped,reason=\"exited-normally\",thread-group=\"i1\"'; while [ -n \"$s\" ]; do printf %s \"${s%\"${s#?}\"}\"; s=${s#?}; sleep 0.01; done; echo",fds);
  ck(pid>0);
  t0=tsh_clock();
  r=g.wait(MR_EXEC,"stopped",1500);
  e=tsh_clock()-t0;
  ck(r!=0);
  ck(gteq(r->str("reason"),"exited-normally"));
  ck(e<1500);
  r->done();
  tsh_wait(pid,1);
  tsh_close(fds[0]);
  g.stop();
  return 0;
}

func main(argc:int,argv:**char)
{
  var g,h:sgdb;
  var r:*mirec;
  var gdb:*char;
  var seen,n,bad:int;
  gtqueue();
  gtclock();
  if(argc<2)return 42;
  gdb="gdb";
  if(argc>2)gdb=argv[2];
  gtlen=0;
  ck(h.start(argv[1],"/nonexistent/uplnc-no-gdb")==0-3);
  ck(h.stop()==127);
  ck(h.start("/nonexistent/uplnc-no-program",gdb)==0-6);
  ck(h.stop()==0);
  ck(g.start(argv[1],gdb)==0);
  r=g.result("-break-insert gdbprog.e:7",10000);
  ck(r!=0);
  ck(gteq(r->cls,"done"));
  ck(gteq(r->str("bkpt.line"),"7"));
  ck(gteq(r->str("bkpt.func"),"add"));
  r->done();
  r=g.result("-exec-run",10000);
  ck(r!=0);
  ck(gteq(r->cls,"running"));
  r->done();
  r=g.wait(MR_EXEC,"stopped",30000);
  ck(r!=0);
  ck(gteq(r->str("reason"),"breakpoint-hit"));
  ck(gteq(r->str("frame.func"),"add"));
  ck(gteq(r->str("frame.line"),"7"));
  ck(gteq(r->str("frame.args.0.name"),"a"));
  ck(gteq(r->str("frame.args.0.value"),"40"));
  r->done();
  ck(gtsee(&g,"hello"));          /* printed before the breakpoint */
  r=g.result("-data-evaluate-expression a+b",10000);
  ck(r!=0);
  ck(gteq(r->str("value"),"42"));
  r->done();
  r=g.result("-stack-list-frames",10000);
  ck(r!=0);
  ck(gteq(r->str("stack.1.func"),"main"));
  r->done();
  r=g.result("-exec-continue",10000);
  ck(r!=0);
  ck(gteq(r->cls,"running"));
  r->done();
  ck(g.ptywrite("q\n",2)==2);     /* main's getchar reads it */
  r=g.wait(MR_EXEC,"stopped",30000);
  ck(r!=0);
  ck(gteq(r->str("reason"),"exited"));
  ck(gdnum(r->str("exit-code"))==42);
  r->done();
  ck(gtsee(&g,"x=42 ch=q"));
  r=g.result("-break-insert nosuchfn",10000);
  ck(r!=0);
  ck(gteq(r->cls,"error"));
  ck(strstr(r->str("msg"),"nosuchfn")!=0);
  r->done();
  /* the console text gdb sent along the way stayed queued, in order */
  seen=0;
  r=g.take();
  while(r)
  {
    if((r->type==MR_CONSOLE)&&strstr(r->text,"Breakpoint 1, add"))seen=1;
    r->done();
    r=g.take();
  }
  ck(seen);
  /* far more than one read: lines reassembled across reads, none lost */
  r=g.result("-interpreter-exec console \"help all\"",30000);
  ck(r!=0);
  ck(gteq(r->cls,"done"));
  r->done();
  n=0;
  bad=0;
  r=g.take();
  while(r)
  {
    if(r->type==MR_CONSOLE)n=n+gdlen(r->text);
    else if(r->type==MR_OTHER)bad++;
    r->done();
    r=g.take();
  }
  ck(n>20000);
  ck(bad==0);
  ck(g.stop()==0);
  return 42;
}
