/* buf.e: the IDE's editable text buffer. See buf.he for the shape.

   Every operation is bounds-checked and does nothing on an out-of-range
   index, so the editor's cursor arithmetic cannot corrupt the buffer -- a
   miscalculated column becomes a no-op rather than a wild store.

   File model: load splits on newline, and a final newline does not create an
   extra empty line; save writes every line followed by a newline. A file that
   did not end with a newline therefore gains one, which is the usual editor
   behaviour and keeps the round trip exact for source files.

   Undo: each primitive that changes text logs the change (ulog) before
   making it, unless uoff is set -- as it is while undo and redo replay the
   log, while load builds a new text, and while split and join use insline
   and delline internally, so one Enter is one record, not two. */

#include "buf.he"

func malloc(n:int);
func realloc(p:int,n:int);
func free(p:int);
func exit(c:int);
func fopen(n:*char,m:*char):*int;
func fgetc(fp:*int);
func fputc(c:int,fp:*int);
func fclose(fp:*int);
func fflush(fp:*int);
func ferror(fp:*int);
func mkstemp(n:*char);
func fdopen(fd:int,m:*char):*int;
func close(fd:int);
func fchmod(fd:int,mode:int);
func unlink(n:*char);
func rename(old:*char,new:*char);
func realpath(n:*char,resolved:*char):*char;
func statx(dirfd:int,n:*char,flags:int,mask:int,buf:*char);
func umask(mask:int);
var extern stderr:*int;

#define BF_STATX_MODE 2
#define BF_AT_FDCWD -100
#define BF_AT_SYMLINK 256

func bfoom()
{
  fprintf(stderr,"buf: out of memory\n");
  exit(2);
  return 0;
}

/* a heap copy of the first len bytes of s */
func bfdup(s:*char,len:int):*char
{
  var p:*char;
  var i:int;
  p=malloc(len+1);
  if(!p)bfoom();
  for(i=0;i<len;i++)p[i]=s[i];
  p[len]=0;
  return p;
}

method sbuf.init()
{
  a=BF_ROWS0;
  l=malloc(a*sizeof(sbline));
  if(!l)bfoom();
  n=1;
  l[0].cap=BF_CHUNK;
  l[0].s=malloc(BF_CHUNK);
  if(!l[0].s)bfoom();
  l[0].s[0]=0;
  l[0].len=0;
  dirty=0;
  u=0;un=0;utop=0;ua=0;usave=0;uoff=0;uopen=0;uhave=0;uy=0;ux=0;
  return 0;
}

method sbuf.done()
{
  var i:int;
  if(!l)return 0;
  for(i=0;i<n;i++)if(l[i].s)free(l[i].s);
  free(l);
  l=0;
  n=0;
  a=0;
  this->utrim(0);
  if(u)free(u);
  u=0;ua=0;usave=0;uopen=0;uhave=0;
  return 0;
}

method sbuf.grow(need:int)
{
  if(need<=a)return 0;
  while(a<need)a=a*2;
  l=realloc(l,a*sizeof(sbline));
  if(!l)bfoom();
  return 0;
}

method sbuf.setcap(i:int,c:int)
{
  var nc:int;
  if((i<0)||(i>=n))return 0;
  if(c+1<=l[i].cap)return 0;
  nc=l[i].cap;
  while(nc<c+1)nc=nc*2;
  l[i].s=realloc(l[i].s,nc);
  if(!l[i].s)bfoom();
  l[i].cap=nc;
  return 0;
}

method sbuf.insline(i:int)
{
  var j:int;
  if((i<0)||(i>n))return 0;
  if(!uoff)this->ulog(BU_INSLINE,i,0,0,0);
  this->grow(n+1);
  for(j=n;j>i;j--)
  {
    l[j].s=l[j-1].s;
    l[j].len=l[j-1].len;
    l[j].cap=l[j-1].cap;
  }
  l[i].cap=BF_CHUNK;
  l[i].s=malloc(BF_CHUNK);
  if(!l[i].s)bfoom();
  l[i].s[0]=0;
  l[i].len=0;
  n=n+1;
  dirty=1;
  return 0;
}

method sbuf.delline(i:int)
{
  var j:int;
  if((i<0)||(i>=n))return 0;
  if(!uoff)this->ulog(BU_DELLINE,i,l[i].len,n==1,bfdup(l[i].s,l[i].len));
  if(n==1)                 /* the last line is emptied, never removed */
  {
    l[0].s[0]=0;
    l[0].len=0;
    dirty=1;
    return 0;
  }
  free(l[i].s);
  for(j=i;j<n-1;j++)
  {
    l[j].s=l[j+1].s;
    l[j].len=l[j+1].len;
    l[j].cap=l[j+1].cap;
  }
  n=n-1;
  dirty=1;
  return 0;
}

method sbuf.line(i:int)
{
  if((i<0)||(i>=n))return "";
  return l[i].s;
}

method sbuf.llen(i:int)
{
  if((i<0)||(i>=n))return 0;
  return l[i].len;
}

method sbuf.insch(i:int,col:int,c:int)
{
  var j:int;
  if((i<0)||(i>=n))return 0;
  if((col<0)||(col>l[i].len))return 0;
  if(!uoff)this->ulog(BU_INSCH,i,col,c,0);
  this->setcap(i,l[i].len+1);
  for(j=l[i].len;j>col;j--)l[i].s[j]=l[i].s[j-1];
  l[i].s[col]=c;
  l[i].len=l[i].len+1;
  l[i].s[l[i].len]=0;
  dirty=1;
  return 0;
}

method sbuf.delch(i:int,col:int)
{
  var j:int;
  if((i<0)||(i>=n))return 0;
  if((col<0)||(col>=l[i].len))return 0;
  if(!uoff)this->ulog(BU_DELCH,i,col,l[i].s[col],0);
  for(j=col;j<l[i].len-1;j++)l[i].s[j]=l[i].s[j+1];
  l[i].len=l[i].len-1;
  l[i].s[l[i].len]=0;
  dirty=1;
  return 0;
}

method sbuf.split(i:int,col:int)
{
  var j,tail:int;
  if((i<0)||(i>=n))return 0;
  if((col<0)||(col>l[i].len))return 0;
  if(!uoff)this->ulog(BU_SPLIT,i,col,0,0);
  tail=l[i].len-col;
  uoff++;
  this->insline(i+1);
  uoff--;
  this->setcap(i+1,tail);
  for(j=0;j<tail;j++)l[i+1].s[j]=l[i].s[col+j];
  l[i+1].s[tail]=0;
  l[i+1].len=tail;
  l[i].len=col;
  l[i].s[col]=0;
  dirty=1;
  return 0;
}

method sbuf.join(i:int)
{
  var j,at:int;
  if((i<0)||(i+1>=n))return 0;
  if(!uoff)this->ulog(BU_JOIN,i,l[i].len,0,0);
  at=l[i].len;
  this->setcap(i,at+l[i+1].len);
  for(j=0;j<l[i+1].len;j++)l[i].s[at+j]=l[i+1].s[j];
  l[i].len=at+l[i+1].len;
  l[i].s[l[i].len]=0;
  uoff++;
  this->delline(i+1);
  uoff--;
  dirty=1;
  return 0;
}

/* statx has one 256-byte ABI on every supported Linux target. stx_mode is the
   16-bit field at byte 28; decode it in the target's byte order. */
func bffilemode(nm:*char)
{
  var [256]char:x;
  var one,mode:int;
  var p:*char;
  if(statx(BF_AT_FDCWD,nm,0,BF_STATX_MODE,x))return -1;
  one=1;p=&one;
  if(p[0])mode=(x[28]&255)|((x[29]&255)<<8);
  else mode=((x[28]&255)<<8)|(x[29]&255);
  return mode&4095;
}

/* Recover a signed C int from the low 32 bits of UPLNC's word-sized int. */
func bfcint(v:int)
{
  var low:int;
  low=v&2147483647;
  if((v>>31)&1)return low-2147483647-1;
  return low;
}

func bfexists(nm:*char)
{
  var [256]char:x;
  return statx(BF_AT_FDCWD,nm,BF_AT_SYMLINK,BF_STATX_MODE,x)==0;
}

/* mkstemp starts at 0600. New editor files should instead observe the process
   umask just like fopen(...,"w"); existing files retain their current mode. */
func bfnewmode()
{
  var old:int;
  old=umask(0);
  umask(old);
  return 438&(~old);       /* 0666 */
}

/* Appending the template keeps the temporary in the destination directory,
   which is required for rename to be atomic. */
func bftempname(nm:*char):*char
{
  var p,s:*char;
  var i,j:int;
  s=".uplnc.XXXXXX";
  i=0;while(nm[i])i++;
  p=malloc(i+14);
  if(!p)return 0;
  for(j=0;j<i;j++)p[j]=nm[j];
  j=0;while(s[j]){p[i+j]=s[j];j++;}
  p[i+j]=0;
  return p;
}

method sbuf.load(nm:*char)
{
  var fp:*int;
  var c,bad:int;
  var sbuf:t;
  fp=fopen(nm,"r");
  if(!fp)return 0;
  t.init();
  t.uoff=1;                      /* a loaded text starts with no history */
  while((c=fgetc(fp))>=0)
  {
    if(c==10)
    {
      t.insline(t.n);            /* a newline ends this line */
      continue;
    }
    t.insch(t.n-1,t.l[t.n-1].len,c);
  }
  bad=ferror(fp);
  if(fclose(fp))bad=1;
  if(bad){t.done();return 0;}
  /* a trailing newline ended the last line: drop the empty line it opened,
     but never below the one line the buffer always keeps */
  if((t.n>1)&&(t.l[t.n-1].len==0))t.delline(t.n-1);
  /* The complete replacement is now known-good. Steal its allocations only
     now, so every fopen/fgetc/fclose failure leaves this buffer untouched.
     done() also drops this buffer's undo log, which described the old text. */
  this->done();
  l=t.l;n=t.n;a=t.a;
  dirty=0;
  return 1;
}

method sbuf.save(nm:*char)
{
  var fp:*int;
  var real,tmp,dst:*char;
  var i,j,fd,mode,bad:int;
  /* Resolve an existing file so replacing through a symlink updates its target
     rather than replacing the link itself. A missing path is a new file. */
  real=realpath(nm,0);
  if(real)
  {
    dst=real;
    mode=bffilemode(real);
    if(mode<0){free(real);return 0;}
  }
  else
  {
    /* realpath fails for a dangling symlink too. Do not replace that link as
       though it were a brand-new path; report failure and leave it intact. */
    if(bfexists(nm))return 0;
    dst=nm;
    mode=bfnewmode();
  }
  tmp=bftempname(dst);
  if(!tmp){if(real)free(real);return 0;}
  fd=bfcint(mkstemp(tmp));
  if(fd<0){free(tmp);if(real)free(real);return 0;}
  if(fchmod(fd,mode))
  {
    close(fd);unlink(tmp);free(tmp);if(real)free(real);
    return 0;
  }
  fp=fdopen(fd,"w");
  if(!fp)
  {
    close(fd);unlink(tmp);free(tmp);if(real)free(real);
    return 0;
  }
  for(i=0;i<n;i++)
  {
    for(j=0;j<l[i].len;j++)fputc(l[i].s[j],fp);
    fputc(10,fp);
  }
  bad=0;
  if(fflush(fp))bad=1;
  if(ferror(fp))bad=1;
  if(fclose(fp))bad=1;
  if(bad)
  {
    unlink(tmp);free(tmp);if(real)free(real);
    return 0;
  }
  if(rename(tmp,dst))
  {
    unlink(tmp);free(tmp);if(real)free(real);
    return 0;
  }
  free(tmp);if(real)free(real);
  dirty=0;
  usave=un;
  return 1;
}

/* End the current undo group: the next change starts a new one, which undo
   reverts as a whole, putting the cursor back at y,x. The editor marks with
   the cursor as it was before the command that is about to edit. */
method sbuf.mark(y:int,x:int)
{
  uopen=0;
  uhave=1;
  umy=y;
  umx=x;
  return 0;
}

/* drop the records from index i on */
method sbuf.utrim(i:int)
{
  var j:int;
  for(j=i;j<utop;j++)if(u[j].text)free(u[j].text);
  utop=i;
  if(un>utop)un=utop;
  return 0;
}

/* append one record and put it in effect */
method sbuf.upush(op:int,y:int,x:int,ch:int,text:*char)
{
  if(utop>=ua)
  {
    if(ua<64)ua=64;
    else ua=ua*2;
    u=realloc(u,ua*sizeof(sbundo));
    if(!u)bfoom();
  }
  u[utop].op=op;
  u[utop].y=y;
  u[utop].x=x;
  u[utop].ch=ch;
  u[utop].text=text;
  utop++;
  un=utop;
  return 0;
}

/* Log a change that is about to be made. Whatever could have been redone is
   dropped first -- and with it the saved state, if that lay there -- and a
   group mark goes in first unless the newest group is still open. A group
   nobody marked records the change's own position as its cursor. */
method sbuf.ulog(op:int,y:int,x:int,ch:int,text:*char)
{
  this->utrim(un);
  if(usave>un)usave=0-1;
  if(!uopen)
  {
    if(uhave)this->upush(BU_MARK,umy,umx,0,0);
    else this->upush(BU_MARK,y,x,0,0);
    uopen=1;
    uhave=0;
  }
  this->upush(op,y,x,ch,text);
  return 0;
}

/* Revert the newest group, its last change first. 1 with the cursor its
   mark recorded in uy,ux, or 0 when there is nothing to undo. The buffer is
   clean again exactly when this returns it to the last saved state. */
method sbuf.undo()
{
  var op,y,x,j:int;
  var t:*char;
  if(un<=0)return 0;
  uoff++;
  while(un>0)
  {
    un--;
    op=u[un].op;
    y=u[un].y;
    x=u[un].x;
    uy=y;
    ux=x;
    if(op==BU_MARK)break;
    if(op==BU_INSCH)this->delch(y,x);
    else if(op==BU_DELCH)this->insch(y,x,u[un].ch);
    else if(op==BU_SPLIT)this->join(y);
    else if(op==BU_JOIN)this->split(y,x);
    else if(op==BU_INSLINE)this->delline(y);
    else if(op==BU_DELLINE)
    {
      if(!u[un].ch)this->insline(y);
      t=u[un].text;
      for(j=0;j<x;j++)this->insch(y,j,t[j]);
    }
  }
  uoff--;
  uopen=0;
  uhave=0;
  dirty=(un!=usave);
  return 1;
}

/* Reapply the group undo reverted last, in its original order. 1 with the
   cursor just after its last change in uy,ux, or 0 when there is nothing to
   redo. A new change discards whatever could still have been redone. */
method sbuf.redo()
{
  var op,y,x:int;
  if(un>=utop)return 0;
  uoff++;
  uy=u[un].y;                    /* the group's mark */
  ux=u[un].x;
  un++;
  while(un<utop)
  {
    op=u[un].op;
    if(op==BU_MARK)break;
    y=u[un].y;
    x=u[un].x;
    if(op==BU_INSCH)
    {
      this->insch(y,x,u[un].ch);
      x++;
    }
    else if(op==BU_DELCH)this->delch(y,x);
    else if(op==BU_SPLIT)
    {
      this->split(y,x);
      y++;
      x=0;
    }
    else if(op==BU_JOIN)this->join(y);
    else if(op==BU_INSLINE)this->insline(y);
    else if(op==BU_DELLINE)
    {
      this->delline(y);
      x=0;
    }
    uy=y;
    ux=x;
    un++;
  }
  uoff--;
  uopen=0;
  uhave=0;
  dirty=(un!=usave);
  return 1;
}
