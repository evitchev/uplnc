/* build.e: the IDE's F9 build and its messages (IDE.md phase 1). bdrun runs
   the driver -- perl langdrv.pl -march=<host> -o <exe> <units> -- through
   the shim's tsh_run, which keeps the child off the raw-mode terminal and
   captures its stdout and stderr together. The editor saves first; bdrun
   never touches the buffer.

   The units are the open file alone, or a project's. A project file (Turbo
   C's .PRJ, as plain text) names one unit per line -- .e sources, and .c,
   .s or .o files the driver also takes -- relative to the project file's
   own directory unless absolute; blank lines and lines starting with # are
   skipped. Its program is the project file without .prj, so app.prj
   builds app beside it. The project is read again at every build, so
   editing it in the IDE takes effect at once.

   The captured text is kept as one message per line. A line that starts
   with "<file>:<line>:" -- the shape langc, lpp1, gcc and as all print -- is
   a location the editor can jump to; every other line (langc's echo of the
   source line and its caret, the driver's summary, linker output) is shown
   as context but skipped by next/previous error. A location is shown from
   its file's base name on (bmshow), so the message itself stays on screen,
   and when langc's caret line follows it, its column is kept too. */

func tsh_run(argv:**char,out:*char,cap:int,outn:*int);
func tsh_machine(buf:*char,cap:int);
func fopen(n:*char,m:*char):*int;
func fgetc(fp:*int);
func fclose(fp:*int);
func malloc(n:int);
func realloc(p:int,n:int);
func free(p:int);
func exit(c:int);
func getenv(n:*char):*char;
func realpath(n:*char,resolved:*char):*char;
func bfexists(nm:*char);
var extern stderr:*int;

#define BM_CAP 65536     /* captured build output kept per build, in bytes */
#define BD_LINE 1024     /* the longest project line kept, with its NUL */

var bmbuf:*char;         /* the captured output, its lines NUL-terminated */
var bmtext:**char;       /* each message line */
var bmfile:**char;       /* its location's file (a heap copy), or 0 */
var bmline:*int;         /* its location's line number, or 0 */
var bmcol:*int;          /* the column langc's caret marks, or -1 */
var bmbase:*int;         /* where the file's base name starts in the text */
var bmn,bma:int;
var bmsel:int;           /* the selected message, or -1 */
var bmexe:*char;         /* the last build's output program */
var bdprj:*char;         /* the project file (heap), or 0 for none */
var bdunit:**char;       /* the units bdunits read last (heap) */
var bdnu,bdua:int;

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

/* does s end with ext (".e", ".prj"), with something before it? */
func bdext(s:*char,ext:*char)
{
  var n,m:int;
  n=bmlen(s);
  m=bmlen(ext);
  return (n>m)&&bdeq(s+n-m,ext);
}

/* the program a build of `file` makes: file without its extension ext, or
   file.out when it has another one */
func bdexe(file:*char,ext:*char):*char
{
  var n:int;
  var p:*char;
  n=bmlen(file);
  if(bdext(file,ext))return bmdup(file,n-bmlen(ext));
  p=malloc(n+5);
  if(!p)bmoom();
  bdcat(p,bdcat(p,0,file),".out");
  return p;
}

/* forget the units bdunits read */
func bdfreeunits()
{
  var i:int;
  for(i=0;i<bdnu;i++)free(bdunit[i]);
  bdnu=0;
  return 0;
}

/* add unit s (n bytes) of a project in directory dir (dn bytes, 0 when the
   project file has no directory part, or when s is absolute) */
func bdaddunit(dir:*char,dn:int,s:*char,n:int)
{
  var p:*char;
  var i:int;
  if(bdnu>=bdua)
  {
    bdua=bdua*2;
    if(bdua<16)bdua=16;
    bdunit=realloc(bdunit,bdua*sizeof(*char));
    if(!bdunit)bmoom();
  }
  if(s[0]=='/')dn=0;
  p=malloc(dn+n+1);
  if(!p)bmoom();
  for(i=0;i<dn;i++)p[i]=dir[i];
  for(i=0;i<n;i++)p[dn+i]=s[i];
  p[dn+n]=0;
  bdunit[bdnu++]=p;
  return 0;
}

/* Read project file prj into bdunit[0..n-1]: n, or -1 if it cannot be
   read. Each line is trimmed of surrounding blanks; a blank line or one
   starting with # names nothing. */
func bdunits(prj:*char)
{
  var [BD_LINE]char:t;
  var fp:*int;
  var c,n,dn,i,st,en:int;
  bdfreeunits();
  fp=fopen(prj,"r");
  if(!fp)return 0-1;
  dn=0;
  for(i=0;prj[i];i++)if(prj[i]=='/')dn=i+1;
  n=0;
  c=0;
  while(c>=0)
  {
    c=fgetc(fp);
    if((c>=0)&&(c!=10))
    {
      if(n<BD_LINE-1)t[n++]=c;
      continue;
    }
    st=0;
    en=n;
    while((st<en)&&((t[st]==' ')||(t[st]==9)))st++;
    while((en>st)&&((t[en-1]==' ')||(t[en-1]==9)||(t[en-1]==13)))en--;
    if((en>st)&&(t[st]!='#'))bdaddunit(prj,dn,t+st,en-st);
    n=0;
  }
  fclose(fp);
  return bdnu;
}

/* the project's file name without its directory, or "" without one */
func bdprjname():*char
{
  var i,b:int;
  if(!bdprj)return "";
  b=0;
  for(i=0;bdprj[i];i++)if(bdprj[i]=='/')b=i+1;
  return bdprj+b;
}

/* a build failed before the driver ran: msg and s as its one message */
func bdfail(msg:*char,s:*char)
{
  bdcat(bmbuf,bdcat(bmbuf,0,msg),s);
  bmadd(bmbuf);
  return 0-1;
}

/* Build the project, or `file` when there is none (a file that is itself a
   project file builds as one): the driver's exit status (0 is success),
   with its output as the messages; -1 if the build could not be started --
   no driver, an unreadable or empty project -- with the reason as the one
   message. */
func bdrun(file:*char)
{
  var av:**char;
  var [80]char:march;
  var drv,prj:*char;
  var n,rc,i:int;
  bmclear();
  if(!bmbuf)
  {
    bmbuf=malloc(BM_CAP+1);
    if(!bmbuf)bmoom();
  }
  drv=bddriver();
  if(!drv)
  {
    return bdfail("cannot find langdrv.pl: set UPLNC_DRIVER to its path","");
  }
  prj=bdprj;
  if((!prj)&&bdext(file,".prj"))prj=file;
  if(bmexe)free(bmexe);
  if(prj)
  {
    n=bdunits(prj);
    if(n<0)return bdfail("cannot read project file ",prj);
    if(!n)return bdfail("no units listed in project file ",prj);
    bmexe=bdexe(prj,".prj");
  }
  else
  {
    bdfreeunits();
    bdaddunit("",0,file,bmlen(file));
    bmexe=bdexe(file,".e");
  }
  bdcat(march,bdcat(march,0,"-march="),bdmarch());
  av=malloc((bdnu+6)*sizeof(*char));
  if(!av)bmoom();
  av[0]="perl";
  av[1]=drv;
  av[2]=march;
  av[3]="-o";
  av[4]=bmexe;
  for(i=0;i<bdnu;i++)av[5+i]=bdunit[i];
  av[5+bdnu]=0;
  n=0;
  rc=tsh_run(av,bmbuf,BM_CAP,&n);
  free(av);
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
