/* mi.e: gdb/MI output records, parsed. See mi.he for the shape.

   One recursive-descent pass over a private copy of the line, nesting at
   most MI_DEPTH deep. A parse that fails anywhere sets mi_bad; miparse then
   frees whatever it built and hands back the line as MR_OTHER, so no input
   -- truncated, garbled or hostile -- can crash the caller, recurse without
   bound, or leave it holding a half-built record.

   The grammar is gdb's (MI "Output Syntax"), with one tolerance: an element
   of a tuple or list may lack its name. gdb releases before 13 print the
   extra locations of a breakpoint that way, as bare {...} tuples after
   bkpt={...}; they are kept, with name 0. */

#include "mi.he"

func calloc(n:int,sz:int);
func malloc(n:int);
func free(p:int);
func exit(c:int);
var extern stderr:*int;

var mi_p:*char;          /* the parse position */
var mi_bad:int;          /* the line is not a well-formed record */

func mioom()
{
  fprintf(stderr,"ide: out of memory\n");
  exit(2);
}

func milen(s:*char)
{
  var n:int;
  n=0;
  while(s[n])n++;
  return n;
}

func mieq(a:*char,b:*char)
{
  var i:int;
  i=0;
  while(a[i]&&(a[i]==b[i]))i++;
  return a[i]==b[i];
}

/* a heap copy of the first n bytes of s */
func midup(s:*char,n:int):*char
{
  var p:*char;
  var i:int;
  p=malloc(n+1);
  if(!p)mioom();
  for(i=0;i<n;i++)p[i]=s[i];
  p[n]=0;
  return p;
}

/* a byte of a result name or a record class */
func minamec(c:int)
{
  if((c>='a')&&(c<='z'))return 1;
  if((c>='A')&&(c<='Z'))return 1;
  if((c>='0')&&(c<='9'))return 1;
  return (c=='-')||(c=='_');
}

func minew(k:int):*mival
{
  var v:*mival;
  v=calloc(1,sizeof(mival));
  if(!v)mioom();
  v->kind=k;
  return v;
}

method mival.done()
{
  var k,nx:*mival;
  k=kids;
  while(k)
  {
    nx=k->next;
    k->done();
    k=nx;
  }
  if(name)free(name);
  if(str)free(str);
  free(this);
  return 0;
}

method mival.get(nm:*char):*mival
{
  var k:*mival;
  for(k=kids;k;k=k->next)
  if(k->name&&mieq(k->name,nm))return k;
  return 0;
}

method mival.at(i:int):*mival
{
  var k:*mival;
  if(i<0)return 0;
  k=kids;
  while(k&&i)
  {
    k=k->next;
    i--;
  }
  return k;
}

method mival.count()
{
  var n:int;
  var k:*mival;
  n=0;
  for(k=kids;k;k=k->next)n++;
  return n;
}

/* Walk p from this value: components separated by '.', each the name of an
   element, or all digits for the element at that index. 0 if any step is
   missing, empty, or longer than a name can be. */
method mival.path(p:*char):*mival
{
  var [64]char:c;
  var v:*mival;
  var i,n,num,digits:int;
  v=this;
  i=0;
  while(p[i])
  {
    n=0;
    digits=1;
    num=0;
    while(p[i]&&(p[i]!='.'))
    {
      if(n<63)c[n]=p[i];
      if((p[i]<'0')||(p[i]>'9'))digits=0;
      else if(num<100000)num=num*10+p[i]-'0';
      n++;
      i++;
    }
    if((n==0)||(n>63))return 0;
    c[n]=0;
    if(p[i]=='.')
    {
      i++;
      if(!p[i])return 0;   /* a trailing '.' names nothing */
    }
    if(digits)v=v->at(num);
    else v=v->get(c);
    if(!v)return 0;
  }
  return v;
}

method mirec.done()
{
  if(text)free(text);
  if(res)res->done();
  free(this);
  return 0;
}

method mirec.get(p:*char):*mival
{
  if(!res)return 0;
  return res->path(p);
}

method mirec.str(p:*char):*char
{
  var v:*mival;
  v=this->get(p);
  if(!v)return 0;
  if(v->kind!=MV_STR)return 0;
  return v->str;
}

/* The C string at mi_p, decoded into a heap string; mi_p moves past its
   closing quote. 0 (and mi_bad) when it does not start with a quote or is
   unterminated. Escapes: \n \t \r \a \b \f \v \e, up to three octal digits,
   and \x for any other x is x itself (\" and \\ among them). An octal \0
   ends the decoded string early; gdb prints none in the records the IDE
   reads. */
func mistr():*char
{
  var s:*char;
  var n,i,k,c,d:int;
  if(mi_p[0]!='"')
  {
    mi_bad=1;
    return 0;
  }
  mi_p++;
  n=0;
  while(mi_p[n]&&(mi_p[n]!='"'))
  {
    if((mi_p[n]=='\\')&&mi_p[n+1])n++;
    n++;
  }
  if(mi_p[n]!='"')
  {
    mi_bad=1;
    return 0;
  }
  s=malloc(n+1);
  if(!s)mioom();
  i=0;
  k=0;
  while(i<n)
  {
    c=mi_p[i];
    i++;
    if(c=='\\')
    {
      c=mi_p[i];
      i++;
      if(c=='n')c=10;
      else if(c=='t')c=9;
      else if(c=='r')c=13;
      else if(c=='a')c=7;
      else if(c=='b')c=8;
      else if(c=='f')c=12;
      else if(c=='v')c=11;
      else if(c=='e')c=27;
      else if((c>='0')&&(c<='7'))
      {
        d=c-'0';
        if((i<n)&&(mi_p[i]>='0')&&(mi_p[i]<='7'))
        {
          d=d*8+mi_p[i]-'0';
          i++;
          if((i<n)&&(mi_p[i]>='0')&&(mi_p[i]<='7'))
          {
            d=d*8+mi_p[i]-'0';
            i++;
          }
        }
        c=d&255;
      }
    }
    s[k]=c;
    k++;
  }
  s[k]=0;
  mi_p=mi_p+n+1;
  return s;
}

func mivalue(depth:int):*mival;

/* The elements of v, a tuple or list whose opening byte is behind mi_p,
   up to the closing byte e (0 for the end of the line: a record's results).
   Each is name=value, or a value alone. */
func mielems(v:*mival,e:int,depth:int)
{
  var last,k:*mival;
  var nm:*char;
  var n:int;
  last=0;
  if(e&&(mi_p[0]==e))
  {
    mi_p++;
    return 0;
  }
  while(1)
  {
    nm=0;
    if(minamec(mi_p[0]))
    {
      n=0;
      while(minamec(mi_p[n]))n++;
      if(mi_p[n]!='=')
      {
        mi_bad=1;
        return 0;
      }
      nm=midup(mi_p,n);
      mi_p=mi_p+n+1;
    }
    k=mivalue(depth);
    if(mi_bad)
    {
      if(nm)free(nm);
      return 0;
    }
    k->name=nm;
    if(last)last->next=k;
    else v->kids=k;
    last=k;
    if(mi_p[0]==',')mi_p++;
    else if(mi_p[0]==e)
    {
      if(e)mi_p++;
      return 0;
    }
    else
    {
      mi_bad=1;
      return 0;
    }
  }
}

/* the value at mi_p: a C string, {tuple} or [list]; 0 and mi_bad if none */
func mivalue(depth:int):*mival
{
  var v:*mival;
  var e:int;
  if(mi_p[0]=='"')
  {
    v=minew(MV_STR);
    v->str=mistr();
    if(mi_bad)
    {
      v->done();
      return 0;
    }
    return v;
  }
  if(mi_p[0]=='{')
  {
    v=minew(MV_TUPLE);
    e='}';
  }
  else if(mi_p[0]=='[')
  {
    v=minew(MV_LIST);
    e=']';
  }
  else
  {
    mi_bad=1;
    return 0;
  }
  if(depth>=MI_DEPTH)
  {
    v->done();
    mi_bad=1;
    return 0;
  }
  mi_p++;
  mielems(v,e,depth+1);
  if(mi_bad)
  {
    v->done();
    return 0;
  }
  return v;
}

/* (gdb), alone but for blanks */
func miprompt(s:*char)
{
  var i:int;
  if((s[0]!='(')||(s[1]!='g')||(s[2]!='d')||(s[3]!='b')||(s[4]!=')'))return 0;
  i=5;
  while(s[i]==' ')i++;
  return !s[i];
}

/* One line of gdb's output, with or without its line end, as a record.
   Never 0: a line that is not a record comes back as MR_OTHER. */
func miparse(line:*char):*mirec
{
  var r:*mirec;
  var cp:*char;
  var n,t,k,c,stream:int;
  r=calloc(1,sizeof(mirec));
  if(!r)mioom();
  r->token=0-1;
  r->res=minew(MV_TUPLE);
  n=milen(line);
  while((n>0)&&((line[n-1]==10)||(line[n-1]==13)))n--;
  cp=midup(line,n);
  if(miprompt(cp))
  {
    r->type=MR_PROMPT;
    free(cp);
    return r;
  }
  mi_p=cp;
  mi_bad=0;
  t=0;
  k=0;
  while((mi_p[0]>='0')&&(mi_p[0]<='9'))
  {
    if(k<MI_TOKLEN)t=t*10+mi_p[0]-'0';
    mi_p++;
    k++;
  }
  if(k>MI_TOKLEN)mi_bad=1;
  if(k)r->token=t;
  c=mi_p[0];
  stream=(c=='~')||(c=='@')||(c=='&');
  if(c=='^')r->type=MR_RESULT;
  else if(c=='*')r->type=MR_EXEC;
  else if(c=='+')r->type=MR_STATUS;
  else if(c=='=')r->type=MR_NOTIFY;
  else if(c=='~')r->type=MR_CONSOLE;
  else if(c=='@')r->type=MR_TARGET;
  else if(c=='&')r->type=MR_LOG;
  else mi_bad=1;
  if(!mi_bad)
  {
    mi_p++;
    if(stream)
    {
      /* a stream record: one C string, and no token */
      if(k)mi_bad=1;
      else
      {
        r->text=mistr();
        if(mi_p[0])mi_bad=1;
      }
    }
    else
    {
      n=0;
      while(minamec(mi_p[n]))n++;
      if((n==0)||(n>=MI_CLASSZ))mi_bad=1;
      else
      {
        for(k=0;k<n;k++)r->cls[k]=mi_p[k];
        r->cls[n]=0;
        mi_p=mi_p+n;
        if(mi_p[0]==',')
        {
          mi_p++;
          mielems(r->res,0,0);   /* "^done," fails there: no value */
        }
        else if(mi_p[0])mi_bad=1;
      }
    }
  }
  if(mi_bad)
  {
    if(r->text)free(r->text);
    r->res->done();
    r->res=minew(MV_TUPLE);
    r->type=MR_OTHER;
    r->token=0-1;
    r->cls[0]=0;
    r->text=cp;
    return r;
  }
  free(cp);
  return r;
}
