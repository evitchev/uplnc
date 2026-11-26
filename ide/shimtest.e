/* shimtest.e: the platform shim's cross-target proof. A pipe round-trip
   through full-width descriptor slots (the packed-C-int hazard the shim
   owns), poll hangup/error classification, a full-count write, and a failing
   read whose -1 must arrive sign-extended -- the exact class of bug cint.he
   exists for. Then the IDE's build runner: captured stdout+stderr, the exit
   status, a killed child, a program that cannot be executed, output past
   the buffer dropped, and the machine name. Then Run's tsh_spawn: the exit
   status, a signal, SIGINT's default restored in the child but ignored by
   the waiting parent, and a program that cannot be executed. Then the
   debugger's child (tsh_child): a pipe each way, its exit status, a write
   to one that has gone failing instead of raising SIGPIPE here, waiting
   without hanging, a kill, SIGPIPE's default back in every kind of child,
   and an unrunnable program; and the debugged program's terminal
   (tsh_openpty) both ways. Exit 42.

   Build: perl src/langdrv.pl -march=ARCH -o shimtest ide/shimtest.e ide/tshim.c */

func tsh_pipe(fds:*int);
func tsh_read(fd:int,buf:*char,n:int);
func tsh_write(fd:int,buf:*char,n:int);
func tsh_poll(fd:int,ms:int);
func tsh_close(fd:int);
func tsh_run(argv:**char,out:*char,cap:int,outn:*int);
func tsh_machine(buf:*char,cap:int);
func tsh_spawn(argv:**char);
func tsh_child(argv:**char,fds:*int);
func tsh_wait(pid:int,hang:int);
func tsh_kill(pid:int,sig:int);
func tsh_openpty(name:*char,cap:int,slave:*int);
func signal(sig:int,handler:int);

#define SIGPIPE 13       /* on every Linux target, MIPS included */
#define SIG_DFL 0

/* read fd until EOF, up to cap bytes, waiting at most 5 s for each */
func rdall(fd:int,buf:*char,cap:int)
{
  var n,r:int;
  n=0;
  while((n<cap)&&(tsh_poll(fd,5000)==1))
  {
    r=tsh_read(fd,buf+n,cap-n);
    if(r<=0)return n;
    n=n+r;
  }
  return n;
}

func main()
{
  var [2]int:fds;
  var [16]char:buf;
  var [4]*char:av;
  var [64]char:out;
  var i,r,n,pid,m,sl:int;
  /* GitHub's runners start jobs with SIGPIPE ignored, and the shim hands
     its children whatever this process started with; start from the
     default, so the checks that children get SIGPIPE back mean something */
  signal(SIGPIPE,SIG_DFL);
  if(tsh_pipe(fds))return 1;
  if(fds[0]==fds[1])return 2;          /* two distinct full-width values */
  for(i=0;i<8;i++)buf[i]='A'+i;
  if(tsh_write(fds[1],buf,8)!=8)return 3;
  for(i=0;i<16;i++)buf[i]=0;
  r=tsh_read(fds[0],buf,16);
  if(r!=8)return 4;
  for(i=0;i<8;i++)if(buf[i]!='A'+i)return 5;
  if(tsh_read(0-1,buf,1)>=0)return 6;  /* -1 must compare negative here */
  if(tsh_close(fds[1]))return 7;
  if(tsh_poll(fds[0],0)!=1)return 8;   /* a hangup makes EOF readable */
  if(tsh_read(fds[0],buf,1)!=0)return 9;
  if(tsh_close(fds[0]))return 10;
  if(tsh_poll(fds[0],0)>=0)return 11;  /* POLLNVAL is an error, not readable */
  av[0]="sh";
  av[1]="-c";
  av[2]="printf hello; printf oops >&2; exit 3";
  av[3]=0;
  n=0-1;
  if(tsh_run(av,out,64,&n)!=3)return 12;
  if(n!=9)return 13;                   /* both streams, in order */
  if((out[0]!='h')||(out[5]!='o')||(out[8]!='s'))return 14;
  av[2]="kill -9 $$";
  if(tsh_run(av,out,64,&n)!=137)return 15;   /* 128 + SIGKILL */
  av[2]="printf 0123456789";
  if(tsh_run(av,out,4,&n)!=0)return 16;
  if((n!=4)||(out[3]!='3'))return 17;  /* the rest is drained, not kept */
  av[0]="/nonexistent/uplnc-no-such-program";
  av[1]=0;
  if(tsh_run(av,out,64,&n)!=127)return 18;
  if((n<10)||(out[0]!='c'))return 19;  /* "cannot run ..." */
  if(tsh_machine(out,64)<0)return 20;
  if(!out[0])return 21;
  av[0]="sh";
  av[1]="-c";
  av[2]="exit 3";
  av[3]=0;
  if(tsh_spawn(av)!=3)return 22;
  av[2]="kill -9 $$";
  if(tsh_spawn(av)!=265)return 23;     /* 256 + SIGKILL */
  av[2]="kill -INT $$; exit 7";         /* SIGINT is the child's again */
  if(tsh_spawn(av)!=258)return 24;
  av[2]="kill -INT $PPID; exit 5";      /* ... but not this process's */
  if(tsh_spawn(av)!=5)return 25;
  tsh_close(2);                         /* its "cannot run" goes nowhere */
  av[0]="/nonexistent/uplnc-no-such-program";
  av[1]=0;
  if(tsh_spawn(av)!=127)return 26;
  /* the debugger's child; stderr is closed now, so a pipe end can be 2 */
  av[0]="cat";
  av[1]=0;
  pid=tsh_child(av,fds);
  if(pid<=0)return 27;
  if(tsh_write(fds[0],"hello\n",6)!=6)return 28;
  r=0;
  while((r<6)&&(tsh_poll(fds[1],5000)==1))
  {
    n=tsh_read(fds[1],buf+r,16-r);
    if(n<=0)break;
    r=r+n;
  }
  if((r!=6)||(buf[0]!='h')||(buf[5]!=10))return 29;
  if(tsh_wait(pid,0)!=0-2)return 30;   /* cat still runs */
  tsh_close(fds[0]);                   /* its stdin at EOF: cat ends */
  if(tsh_wait(pid,1)!=0)return 31;
  if(rdall(fds[1],buf,16)!=0)return 32;
  tsh_close(fds[1]);
  av[0]="sh";
  av[1]="-c";
  av[2]="printf out; printf err >&2; exit 4";
  av[3]=0;
  pid=tsh_child(av,fds);
  if(rdall(fds[1],out,64)!=6)return 33;  /* both streams, in order */
  if((out[0]!='o')||(out[3]!='e'))return 34;
  if(tsh_wait(pid,1)!=4)return 35;
  tsh_close(fds[0]);
  tsh_close(fds[1]);
  av[2]="exit 0";
  pid=tsh_child(av,fds);
  if(tsh_wait(pid,1)!=0)return 36;
  if(tsh_write(fds[0],"x",1)!=0-1)return 37;   /* EPIPE, and still alive */
  tsh_close(fds[0]);
  tsh_close(fds[1]);
  av[2]="sleep 30";
  pid=tsh_child(av,fds);
  if(tsh_wait(pid,0)!=0-2)return 38;
  if(tsh_kill(pid,9))return 39;
  if(tsh_wait(pid,1)!=265)return 40;   /* 256 + SIGKILL */
  if(tsh_wait(pid,1)!=0-1)return 41;   /* reaped: no such child now */
  tsh_close(fds[0]);
  tsh_close(fds[1]);
  /* SIGPIPE is ignored here now; each kind of child gets its default back */
  av[2]="kill -PIPE $$; exit 6";
  if(tsh_spawn(av)!=269)return 43;     /* 256 + SIGPIPE */
  if(tsh_run(av,out,64,&n)!=141)return 44;   /* 128 + SIGPIPE */
  pid=tsh_child(av,fds);
  if(tsh_wait(pid,1)!=269)return 45;
  tsh_close(fds[0]);
  tsh_close(fds[1]);
  av[0]="/nonexistent/uplnc-no-such-program";
  av[1]=0;
  pid=tsh_child(av,fds);
  n=rdall(fds[1],out,64);
  if((n<10)||(out[0]!='c'))return 46;  /* "cannot run ..." */
  if(tsh_wait(pid,1)!=127)return 47;
  tsh_close(fds[0]);
  tsh_close(fds[1]);
  /* the debugged program's terminal, both ways */
  m=tsh_openpty(out,64,&sl);
  if((m<0)||(sl<0)||(m==sl))return 48;
  if((out[0]!='/')||(out[5]!='p'))return 49;   /* /dev/pts/N */
  if(tsh_write(sl,"ab\n",3)!=3)return 50;
  r=0;
  while((r<4)&&(tsh_poll(m,5000)==1))
  {
    n=tsh_read(m,buf+r,16-r);
    if(n<=0)break;
    r=r+n;
  }
  if((r!=4)||(buf[0]!='a')||(buf[2]!=13)||(buf[3]!=10))return 51;  /* ab CR LF */
  if(tsh_write(m,"xy\n",3)!=3)return 52;
  if(tsh_poll(sl,5000)!=1)return 53;
  if(tsh_read(sl,buf,16)!=3)return 54;   /* a whole line, canonical input */
  if((buf[0]!='x')||(buf[2]!=10))return 55;
  if(tsh_close(sl)||tsh_close(m))return 56;
  return 42;
}
