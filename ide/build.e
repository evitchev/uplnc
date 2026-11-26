/* build.e: the IDE's F9 build and its messages (IDE.md phase 1). bdrun runs
   the driver -- perl langdrv.pl -march=<host> -o <exe> <file> -- through
   the shim's tsh_run, which keeps the child off the raw-mode terminal and
   captures its stdout and stderr together. The editor saves first; bdrun
   never touches the buffer.

   The captured text is kept as one message per line. A line that starts
   with "<file>:<line>:" -- the shape langc, lpp1, gcc and as all print -- is
   a location the editor can jump to; every other line (langc's echo of the
   source line and its caret, the driver's summary, linker output) is shown
   as context but skipped by next/previous error. A location is shown from
   its file's base name on (bmshow), so the message itself stays on screen,
   and when langc's caret line follows it, its column is kept too. */

func tsh_run(argv:**char,out:*char,cap:int,outn:*int);
func tsh_machine(buf:*char,cap:int);
func malloc(n:int);
func realloc(p:int,n:int);
func free(p:int);
func exit(c:int);
func getenv(n:*char):*char;
func realpath(n:*char,resolved:*char):*char;
func bfexists(nm:*char);
var extern stderr:*int;

#define BM_CAP 65536     /* captured build output kept per build, in bytes */

var bmbuf:*char;         /* the captured output, its lines NUL-terminated */
var bmtext:**char;       /* each message line */
var bmfile:**char;       /* its location's file (a heap copy), or 0 */
var bmline:*int;         /* its location's line number, or 0 */
var bmcol:*int;          /* the column langc's caret marks, or -1 */
var bmbase:*int;         /* where the file's base name starts in the text */
var bmn,bma:int;
var bmsel:int;           /* the selected message, or -1 */
var bmexe:*char;         /* the last build's output program */

func bmoom()
{
  fprintf(stderr,"ide: out of memory\n");
  exit(2);
}

func bmlen(s:*char)
{
  var n:int;
  n=0;
  while(s[n])n++;
  return n;
}

/* a heap copy of the first n bytes of s */
func bmdup(s:*char,n:int):*char
{
  var p:*char;
  var i:int;
  p=malloc(n+1);
  if(!p)bmoom();
  for(i=0;i<n;i++)p[i]=s[i];
  p[n]=0;
  return p;
}

/* forget every message */
func bmclear()
{
  var i:int;
  for(i=0;i<bmn;i++)
  if(bmfile[i])free(bmfile[i]);
  bmn=0;
  bmsel=0-1;
  return 0;
}

func bmcount(){return bmn;}

/* If s starts with "<file>:<digits>:", the file's length, with the line
   number through ln; otherwise 0. The file part is everything before the
   first ':' that is followed by digits and another ':', so a path may hold
   spaces, while "ld: foo.o: in function" and "(.text+0x10):" never match. */
func bmloc(s:*char,ln:*int)
{
  var i,j,n:int;
  for(i=1;s[i];i++)
  {
    if(s[i]!=':')continue;
    j=i+1;
    n=0;
    while((s[j]>='0')&&(s[j]<='9'))
    {
      n=n*10+s[j]-'0';
      j++;
    }
    if((j>i+1)&&(s[j]==':')&&(n>0))
    {
      *ln=n;
      return i;
    }
  }
  return 0;
}

/* append line s (it stays in place in bmbuf) as message bmn */
func bmadd(s:*char)
{
  var f,ln,i:int;
  if(bmn>=bma)
  {
    bma=bma*2;
    if(bma<64)bma=64;
    bmtext=realloc(bmtext,bma*sizeof(*char));
    bmfile=realloc(bmfile,bma*sizeof(*char));
    bmline=realloc(bmline,bma*sizeof(int));
    bmcol=realloc(bmcol,bma*sizeof(int));
    bmbase=realloc(bmbase,bma*sizeof(int));
    if((!bmtext)||(!bmfile)||(!bmline)||(!bmcol)||(!bmbase))bmoom();
  }
  bmtext[bmn]=s;
  bmfile[bmn]=0;
  bmline[bmn]=0;
  bmcol[bmn]=0-1;
  bmbase[bmn]=0;
  ln=0;
  f=bmloc(s,&ln);
  if(f)
  {
    bmfile[bmn]=bmdup(s,f);
    bmline[bmn]=ln;
    for(i=0;i<f;i++)if(s[i]=='/')bmbase[bmn]=i+1;
  }
  bmn++;
  return 0;
}

/* message i as shown: a location from its file's base name on */
func bmshow(i:int):*char
{
  return bmtext[i]+bmbase[i];
}

/* langc follows an error with the source line and a caret under the
   column: "<spaces>^". Keep that column on the located message. */
func bmcarets()
{
  var i,j:int;
  var p:*char;
  for(i=0;i+2<bmn;i++)
  {
    if(!bmfile[i])continue;
    p=bmtext[i+2];
    j=0;
    while(p[j]==' ')j++;
    if((p[j]=='^')&&!p[j+1])bmcol[i]=j;
  }
  return 0;
}

/* split the first n captured bytes into messages, dropping empty lines */
func bmsplit(n:int)
{
  var i,st:int;
  bmbuf[n]=0;
  st=0;
  for(i=0;i<=n;i++)
  {
    if((i<n)&&(bmbuf[i]!=10))continue;
    bmbuf[i]=0;
    if(i>st)bmadd(bmbuf+st);
    st=i+1;
  }
  bmcarets();
  return 0;
}

/* the build driver: $UPLNC_DRIVER, else src/langdrv.pl beside the IDE's own
   directory or in it (ide/ide finds ../src/langdrv.pl), else in the
   current directory; 0 if there is none */
func bddriver():*char
{
  var p,exe:*char;
  var [4096]char:t;
  var i,cut,n:int;
  p=getenv("UPLNC_DRIVER");
  if(p&&p[0])return p;
  exe=realpath("/proc/self/exe",0);
  if(exe)
  {
    cut=0;
    for(i=0;exe[i];i++)if(exe[i]=='/')cut=i;
    if(cut+32<4096)
    {
      for(i=0;i<=cut;i++)t[i]=exe[i];
      n=cut+1;
      bdcat(t,n,"../src/langdrv.pl");
      if(bfexists(t))
      {
        free(exe);
        return bmdup(t,bmlen(t));
      }
      bdcat(t,n,"langdrv.pl");
      if(bfexists(t))
      {
        free(exe);
        return bmdup(t,bmlen(t));
      }
    }
    free(exe);
  }
  if(bfexists("src/langdrv.pl"))return "src/langdrv.pl";
  return 0;
}

/* copy s into t at n, NUL-terminated */
func bdcat(t:*char,n:int,s:*char)
{
  while(*s)t[n++]=*s++;
  t[n]=0;
  return n;
}

/* -march for this machine: $UPLNC_MARCH, else from uname (the driver's
   own default is i386, which a 64-bit host may not even be able to link) */
func bdmarch():*char
{
  var [64]char:m;
  var p:*char;
  p=getenv("UPLNC_MARCH");
  if(p&&p[0])return p;
  if(tsh_machine(m,64)<0)return "x86_64";
  if(bdeq(m,"aarch64")||bdeq(m,"arm64"))return "arm64";
  if(bdeq(m,"riscv64"))return "riscv64";
  if(bdeq(m,"mips64"))return "mips64";
  if((m[0]=='i')&&(m[2]=='8')&&(m[3]=='6'))return "i386";
  return "x86_64";
}

func bdeq(a:*char,b:*char)
{
  while(*a&&(*a==*b))
  {
    a++;
    b++;
  }
  return *a==*b;
}

/* the program a build of `file` makes: file without its .e, or file.out */
func bdexe(file:*char):*char
{
  var n:int;
  var p:*char;
  n=bmlen(file);
  if((n>2)&&(file[n-2]=='.')&&(file[n-1]=='e'))return bmdup(file,n-2);
  p=malloc(n+5);
  if(!p)bmoom();
  bdcat(p,bdcat(p,0,file),".out");
  return p;
}

/* Build `file`: the driver's exit status (0 is success), with its output
   as the messages; -1 if no driver was found or none could be started. */
func bdrun(file:*char)
{
  var [12]*char:av;
  var [80]char:march;
  var drv:*char;
  var n,rc:int;
  bmclear();
  if(!bmbuf)
  {
    bmbuf=malloc(BM_CAP+1);
    if(!bmbuf)bmoom();
  }
  drv=bddriver();
  if(!drv)
  {
    bdcat(bmbuf,0,"cannot find langdrv.pl: set UPLNC_DRIVER to its path");
    bmadd(bmbuf);
    return 0-1;
  }
  if(bmexe)free(bmexe);
  bmexe=bdexe(file);
  bdcat(march,bdcat(march,0,"-march="),bdmarch());
  av[0]="perl";
  av[1]=drv;
  av[2]=march;
  av[3]="-o";
  av[4]=bmexe;
  av[5]=file;
  av[6]=0;
  n=0;
  rc=tsh_run(av,bmbuf,BM_CAP,&n);
  bmsplit(n);
  return rc;
}

/* the next message with a location after (d=1) or before (d=-1) the
   selection, which it becomes; -1, and no change, if there is none */
func bmnext(d:int)
{
  var i:int;
  i=bmsel+d;
  if(bmsel<0)
  {
    if(d>0)i=0;
    else i=bmn-1;
  }
  while((i>=0)&&(i<bmn))
  {
    if(bmfile[i])
    {
      bmsel=i;
      return i;
    }
    i=i+d;
  }
  return 0-1;
}
