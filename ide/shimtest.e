/* shimtest.e: the platform shim's cross-target proof. A pipe round-trip
   through full-width descriptor slots (the packed-C-int hazard the shim
   owns), poll hangup/error classification, a full-count write, and a failing
   read whose -1 must arrive sign-extended -- the exact class of bug cint.he
   exists for. Then the IDE's build runner: captured stdout+stderr, the exit
   status, a killed child, a program that cannot be executed, output past
   the buffer dropped, and the machine name. Then Run's tsh_spawn: the exit
   status, a signal, SIGINT's default restored in the child but ignored by
   the waiting parent, and a program that cannot be executed. Exit 42.

   Build: perl src/langdrv.pl -march=ARCH -o shimtest ide/shimtest.e ide/tshim.c */

func tsh_pipe(fds:*int);
func tsh_read(fd:int,buf:*char,n:int);
func tsh_write(fd:int,buf:*char,n:int);
func tsh_poll(fd:int,ms:int);
func tsh_close(fd:int);
func tsh_run(argv:**char,out:*char,cap:int,outn:*int);
func tsh_machine(buf:*char,cap:int);
func tsh_spawn(argv:**char);

func main()
{
  var [2]int:fds;
  var [16]char:buf;
  var [4]*char:av;
  var [64]char:out;
  var i,r,n:int;
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
  return 42;
}
