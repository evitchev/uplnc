/* gdb.e: one gdb session. See gdb.he for the shape.

   Waiting: the shim has no clock, so result() and wait() count their
   budget down by each poll's timeout when nothing arrived, and by 1 when
   something did, so a gdb that keeps talking cannot hold them forever.

   Quoting: a command argument that may hold blanks or quotes -- the
   program's path, the pty's -- is sent as an MI C string (gdquote). */

#include "gdb.he"

func malloc(n:int);
func realloc(p:int,n:int);
func free(p:int);
func exit(c:int);
var extern stderr:*int;
func tsh_child(argv:**char,fds:*int);
func tsh_wait(pid:int,hang:int);
func tsh_kill(pid:int,sig:int);
func tsh_openpty(name:*char,cap:int,slave:*int);
func tsh_poll(fd:int,ms:int);
func tsh_read(fd:int,buf:*char,n:int);
func tsh_write(fd:int,buf:*char,n:int);
func tsh_close(fd:int);

#define GD_TICK 50       /* ms per poll while waiting */

func gdoom()
{
  fprintf(stderr,"ide: out of memory\n");
  exit(2);
}

func gdlen(s:*char)
{
  var n:int;
  n=0;
  while(s[n])n++;
  return n;
}

func gdeq(a:*char,b:*char)
{
  var i:int;
  i=0;
  while(a[i]&&(a[i]==b[i]))i++;
  return a[i]==b[i];
}

/* an MI number: gdb prints most in decimal, but an exit-code in octal
   with a leading 0 ("052" is 42) */
func gdnum(s:*char)
{
  var n,i,base:int;
  if(!s)return 0-1;
  n=0;
  base=10;
  if((s[0]=='0')&&s[1])base=8;
  for(i=0;(s[i]>='0')&&(s[i]<=base-1+'0');i++)n=n*base+s[i]-'0';
  return n;
}

/* s as an MI C string into d, which holds 2*len(s)+3 bytes */
func gdquote(d:*char,s:*char)
{
  var i,k:int;
  k=0;
  d[k]='"';
  k++;
  for(i=0;s[i];i++)
  {
    if((s[i]=='"')||(s[i]=='\\'))
    {
      d[k]='\\';
      k++;
    }
    d[k]=s[i];
    k++;
  }
  d[k]='"';
  d[k+1]=0;
  return k+1;
}

/* the command a then the quoted s, as one heap string */
func gdcat(a:*char,s:*char):*char
{
  var d:*char;
  var n,i:int;
  n=gdlen(a);
  d=malloc(n+2*gdlen(s)+3);
  if(!d)gdoom();
  for(i=0;i<n;i++)d[i]=a[i];
  gdquote(d+n,s);
  return d;
}

/* An empty session: no gdb, no pty, empty line buffer and queue. start()
   begins with it; a session fed by hand, through out, can use it alone. */
method sgdb.init()
{
  pid=0;
  in=0-1;
  out=0-1;
  pty=0-1;
  ptys=0-1;
  ptyname[0]=0;
  dead=0;
  ln=0;
  la=GD_LINE;
  lb=malloc(la);
  qa=GD_QUEUE;
  q=malloc(qa*sizeof(int));
  if((!lb)||(!q))gdoom();
  qh=0;
  qn=0;
  tok=0;
  return 0;
}

/* Start gdb (the program at path gdb) for the program prog, on a fresh
   pty. Returns 0, or the negative step that failed: -1 the pty, -2 gdb
   itself, -3 its first prompt, -4..-6 the setup commands (-6: gdb could
   not load prog). The session needs stop() either way. */
method sgdb.start(prog:*char,gdb:*char)
{
  var [6]*char:av;
  var [2]int:fds;
  var r:*mirec;
  var cmd:*char;
  var ms,ok:int;
  this->init();
  pty=tsh_openpty(ptyname,GD_PTYNAME,&this->ptys);
  if(pty<0)return 0-1;
  av[0]=gdb;
  av[1]="--interpreter=mi2";
  av[2]="-nx";
  av[3]="-q";
  av[4]=0;
  pid=tsh_child(av,fds);
  if(pid<=0)
  {
    pid=0;
    return 0-2;
  }
  in=fds[0];
  out=fds[1];
  /* gdb announces itself with a few records and a first prompt */
  ok=0;
  for(ms=10000;(ms>0)&&!ok;ms=ms-GD_TICK)
  {
    if(this->poll(GD_TICK)<0)return 0-3;
    r=this->find(MR_PROMPT,0,0);
    if(r)
    {
      r->done();
      ok=1;
    }
  }
  if(!ok)return 0-3;
  r=this->result("-gdb-set confirm off",10000);
  if((!r)||!gdeq(r->cls,"done"))ok=0;
  if(r)r->done();
  if(!ok)return 0-4;
  /* no symbol downloads: a gdb built with debuginfod would otherwise go to
     the network for every library; one without it answers ^error */
  r=this->result("-gdb-set debuginfod enabled off",10000);
  if(r)r->done();
  cmd=gdcat("-inferior-tty-set ",ptyname);
  r=this->result(cmd,10000);
  free(cmd);
  if((!r)||!gdeq(r->cls,"done"))ok=0;
  if(r)r->done();
  if(!ok)return 0-5;
  cmd=gdcat("-file-exec-and-symbols ",prog);
  r=this->result(cmd,30000);
  free(cmd);
  if((!r)||!gdeq(r->cls,"done"))ok=0;
  if(r)r->done();
  if(!ok)return 0-6;
  return 0;
}

/* Send cmd with the next token, which is returned (-1 if gdb is gone). */
method sgdb.send(cmd:*char)
{
  var [16]char:t;
  var d:*char;
  var n,k,i,v:int;
  if((!pid)||dead)return 0-1;
  tok++;
  v=tok;
  k=0;
  while(v)
  {
    t[k]='0'+v%10;
    v=v/10;
    k++;
  }
  n=gdlen(cmd);
  d=malloc(k+n+2);
  if(!d)gdoom();
  for(i=0;i<k;i++)d[i]=t[k-1-i];
  for(i=0;i<n;i++)d[k+i]=cmd[i];
  d[k+n]=10;
  i=tsh_write(in,d,k+n+1);
  free(d);
  if(i!=k+n+1)return 0-1;
  return tok;
}

method sgdb.push(r:*mirec)
{
  var i:int;
  if(qn==qa)
  {
    if(qh>0)
    {
      for(i=qh;i<qn;i++)q[i-qh]=q[i];
      qn=qn-qh;
      qh=0;
    }
    else
    {
      qa=qa*2;
      q=realloc(q,qa*sizeof(int));
      if(!q)gdoom();
    }
  }
  q[qn]=r;
  qn++;
  return 0;
}

/* Read what gdb sends within ms and queue each whole line as a record.
   The number queued; -1 once gdb's output has ended (a partial last line
   is queued first). */
method sgdb.poll(ms:int)
{
  var [4096]char:buf;
  var n,i,got:int;
  if(dead)return 0-1;
  got=0;
  if(tsh_poll(out,ms)!=1)return 0;
  n=tsh_read(out,buf,4096);
  if(n<=0)
  {
    dead=1;
    if(ln)
    {
      lb[ln]=0;
      this->push(miparse(lb));
      ln=0;
    }
    return 0-1;
  }
  for(i=0;i<n;i++)
  {
    if(buf[i]==10)
    {
      lb[ln]=0;
      this->push(miparse(lb));
      ln=0;
      got++;
    }
    else
    {
      if(ln+1>=la)
      {
        la=la*2;
        lb=realloc(lb,la);
        if(!lb)gdoom();
      }
      lb[ln]=buf[i];
      ln++;
    }
  }
  return got;
}

method sgdb.take():*mirec
{
  var r:*mirec;
  if(qh==qn)return 0;
  r=q[qh];
  qh++;
  if(qh==qn)
  {
    qh=0;
    qn=0;
  }
  return r;
}

/* Take the first queued record of type t whose class is cls (any class
   when cls is 0) -- or, for t MR_RESULT and cls 0, whose token is tk. */
method sgdb.find(t:int,cls:*char,tk:int):*mirec
{
  var r:*mirec;
  var i,j:int;
  for(i=qh;i<qn;i++)
  {
    r=q[i];
    if(r->type!=t)continue;
    if(cls&&!gdeq(r->cls,cls))continue;
    if((t==MR_RESULT)&&!cls&&(r->token!=tk))continue;
    for(j=i+1;j<qn;j++)q[j-1]=q[j];
    qn--;
    return r;
  }
  return 0;
}

/* send cmd and wait up to ms for its result; 0 if gdb ended or ms passed */
method sgdb.result(cmd:*char,ms:int):*mirec
{
  var r:*mirec;
  var t,g:int;
  t=this->send(cmd);
  if(t<0)return 0;
  while(ms>0)
  {
    r=this->find(MR_RESULT,0,t);
    if(r)return r;
    g=this->poll(GD_TICK);
    if(g<0)return this->find(MR_RESULT,0,t);
    if(g)ms--;
    else ms=ms-GD_TICK;
  }
  return 0;
}

/* wait up to ms for a record of type t and class cls (any if 0) */
method sgdb.wait(t:int,cls:*char,ms:int):*mirec
{
  var r:*mirec;
  var g:int;
  while(ms>0)
  {
    r=this->find(t,cls,0);
    if(r)return r;
    g=this->poll(GD_TICK);
    if(g<0)return this->find(t,cls,0);
    if(g)ms--;
    else ms=ms-GD_TICK;
  }
  return 0;
}

/* what the program printed, up to cap bytes, waiting up to ms for any */
method sgdb.ptyread(buf:*char,cap:int,ms:int)
{
  if(pty<0)return 0;
  if(tsh_poll(pty,ms)!=1)return 0;
  return tsh_read(pty,buf,cap);
}

method sgdb.ptywrite(s:*char,n:int)
{
  if(pty<0)return 0-1;
  return tsh_write(pty,s,n);
}

/* Ask gdb to exit (it kills the program first) and close its stdin, which
   it also takes as the end; wait up to 5 s for it to close its output,
   then kill it if it has not; reap it, close everything and free the
   queue. Returns gdb's exit status (256+signal if killed), or -1 if gdb
   never started (a session that was only init'ed). */
method sgdb.stop()
{
  var r:*mirec;
  var st,ms:int;
  st=0-1;
  if(pid)
  {
    if(!dead)this->send("-gdb-exit");
    tsh_close(in);
    in=0-1;
    for(ms=5000;(ms>0)&&!dead;ms=ms-GD_TICK)this->poll(GD_TICK);
    if(!dead)tsh_kill(pid,9);
    st=tsh_wait(pid,1);
    pid=0;
  }
  if(in>=0)tsh_close(in);
  if(out>=0)tsh_close(out);
  if(pty>=0)tsh_close(pty);
  if(ptys>=0)tsh_close(ptys);
  in=0-1;
  out=0-1;
  pty=0-1;
  ptys=0-1;
  r=this->take();
  while(r)
  {
    r->done();
    r=this->take();
  }
  free(q);
  free(lb);
  q=0;
  lb=0;
  return st;
}
