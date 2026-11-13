/* ed.e: the IDE's editor (IDE.md phase 1) -- a Turbo-style menu bar, one
   editor window, a message pane, and F9 build with error jump.

   Keys: arrows/Home/End/PgUp/PgDn move (with Shift they select), printable
   keys and Enter/Backspace/Del edit (Tab enters two spaces; typing over a
   selection replaces it), F2 saves, F3 opens, F9 builds, Alt-F7/Alt-F8 step
   through the build's errors, Ctrl-L repeats the last Find or Replace,
   Shift-Del / Ctrl-Ins / Shift-Ins / Ctrl-Del cut, copy, paste and clear,
   Alt-Backspace undoes, Esc closes the message pane, F10 or Alt+a menu
   letter opens the menus (Alt-F, Alt-E, Alt-S, Alt-C), and Alt-X quits.
   Every command is also on a menu, because terminal emulators keep some of
   those keys for themselves (MATE Terminal opens its own menu bar on F10;
   many paste on Shift-Ins).

   Undo: the buffer logs every change itself (buf.he); the editor only marks
   where one undo step ends. Each command is one step, and so is a run of
   keys of one kind -- typing (up to and including an Enter), Backspaces, or
   Dels -- so Undo takes back one typed line, or one run of deletions.

   Layout: row 0 is the menu bar, row h-1 the status bar, the message pane
   (when open) sits just above the status bar, and the rows between are the
   text viewport. The viewport origin (edtop, edleft) follows the cursor:
   edshow() is the single place that decides what is visible, so every key
   handler only has to move the cursor.

   Build: perl src/langdrv.pl -o ed ide/ed.e ide/menu.e ide/build.e ide/buf.e
          ide/tui.e ide/tshim.c */

#include "tui.he"
#include "buf.he"

func tuiinit();
func tuidone();
func tuiresize();
func tuirows();
func tuicols();
func tuiput(x:int,y:int,c:int,attr:int);
func tuitext(x:int,y:int,s:*char,attr:int);
func tuifill(x:int,y:int,w:int,h:int,c:int,attr:int);
func tuiflush();
func tuicurs(x:int,y:int);
func tuikey(ms:int);
func mninit();
func mnbegin(t:*char);
func mnitem(label:*char,key:*char,cmd:int);
func mnbar(open:int);
func mnfind(c:int);
func mnrun(m:int);
func dlgline(t:*char,prompt:*char,buf:*char,cap:int);
func dlgask(t:*char,text:*char,hint:*char,keys:*char);
func bdrun(file:*char);
func bmcount();
func bmnext(d:int);
func bmshow(i:int):*char;
func malloc(n:int);
func free(p:int);
func exit(c:int);
func realpath(n:*char,resolved:*char):*char;
var extern stderr:*int;
var extern bmtext:**char;
var extern bmfile:**char;
var extern bmline:*int;
var extern bmcol:*int;
var extern bmsel:int;
var extern bmexe:*char;

enum { CM_NONE, CM_OPEN, CM_SAVE, CM_SAVEAS, CM_EXIT, CM_CUT, CM_COPY,
  CM_PASTE, CM_CLEAR, CM_FIND, CM_AGAIN, CM_GOTO, CM_PREVERR, CM_NEXTERR,
  CM_BUILD, CM_MSGS, CM_UNDO, CM_REDO, CM_REPLACE };

/* the undo run an editing key belongs to (see edkindof) */
enum { EK_NONE, EK_TYPE, EK_BS, EK_DEL };

#define ED_PATH 256        /* a path typed into a dialog, with its NUL */
#define ED_FIND 128        /* the search text, with its NUL */
#define ED_PANE 8          /* message pane height, its title row included */

var b:sbuf;
var edcy,edcx:int;         /* cursor: buffer line, column */
var edtop,edleft:int;      /* viewport origin */
var edname:*char;
var edowned:int;           /* edname is a heap copy (not argv's) */
var edmsg:*char;           /* transient status text */
var edtitle,edtext,edstat,edblock,edpanec,edpanesel:int;
var edquit,edrc:int;       /* dirty-quit confirmation and process status */
var edsel,edsy,edsx:int;   /* a selection runs from its anchor to the cursor */
var edy0,edx0,edy1,edx1:int; /* ... ordered by edselnorm */
var edclip:*char;          /* the clipboard: text with newline bytes */
var edfind:[ED_FIND]char;
var edrepl:[ED_FIND]char;  /* Replace's new text */
var edlastrep:int;         /* Search again repeats a Replace, not a Find */
var edmbuf:[80]char;       /* a status message built at run time (edfmt) */
var edpane,edptop:int;     /* message pane open, and its first shown row */
var edkind:int;            /* the undo run the last key continued, or 0 */

/* the message pane's height, 0 when it is closed or the screen too short */
func edpaneh()
{
  var h:int;
  if((!edpane)||(!bmcount()))return 0;
  h=ED_PANE;
  if(h>(tuirows()-2)/2)h=(tuirows()-2)/2;
  if(h<2)return 0;
  return h;
}

func edrows(){return tuirows()-2-edpaneh();}   /* text rows */

func edisquit(k:int){return k==K_ALT+'x';}

func edlen(){return b.llen(edcy);}

func strlen2(s:*char)
{
  var i:int;
  i=0;
  while(s[i])i++;
  return i;
}

/* a heap copy of s */
func eddup(s:*char):*char
{
  var p:*char;
  var i:int;
  p=malloc(strlen2(s)+1);
  if(!p)
  {
    fprintf(stderr,"ed: out of memory\n");
    exit(2);
  }
  for(i=0;s[i];i++)p[i]=s[i];
  p[i]=0;
  return p;
}

func edcopy(d:*char,s:*char,cap:int)
{
  var i:int;
  i=0;
  while(s[i]&&(i<cap-1))
  {
    d[i]=s[i];
    i++;
  }
  d[i]=0;
  return 0;
}

/* keep the cursor inside the buffer and the viewport around the cursor */
func edshow()
{
  var rows,cols:int;
  rows=edrows();
  cols=tuicols();
  if(edcy<0)edcy=0;
  if(edcy>=b.n)edcy=b.n-1;
  if(edcx<0)edcx=0;
  if(edcx>edlen())edcx=edlen();
  if(edcy<edtop)edtop=edcy;
  if(rows>0)if(edcy>=edtop+rows)edtop=edcy-rows+1;
  if(edtop<0)edtop=0;
  if(edcx<edleft)edleft=edcx;
  if(cols>0)if(edcx>=edleft+cols)edleft=edcx-cols+1;
  if(edleft<0)edleft=0;
  return 0;
}

func ednum(x:int,y:int,v:int,attr:int)
{
  if(v>=10)x=ednum(x,y,v/10,attr);
  tuiput(x,y,'0'+v%10,attr);
  return x+1;
}

/* order the selection into edy0,edx0 .. edy1,edx1; 0 if there is none */
func edselnorm()
{
  if(!edsel)return 0;
  if((edsy<edcy)||((edsy==edcy)&&(edsx<=edcx)))
  {
    edy0=edsy;edx0=edsx;edy1=edcy;edx1=edcx;
  }
  else
  {
    edy0=edcy;edx0=edcx;edy1=edsy;edx1=edsx;
  }
  return (edy0!=edy1)||(edx0!=edx1);
}

/* is the character at y,x (x may be the line's end: its newline) selected */
func edinsel(y:int,x:int)
{
  if((y<edy0)||(y>edy1))return 0;
  if((y==edy0)&&(x<edx0))return 0;
  if((y==edy1)&&(x>=edx1))return 0;
  return 1;
}

/* the message pane: a title rule, then the build output, selection lit */
func edpanedraw(y:int,h:int)
{
  var w,i,li,a:int;
  w=tuicols();
  tuifill(0,y,w,1,ACS_HLINE,edpanec+A_ACS);
  tuitext(2,y," Messages ",edpanec);
  h=h-1;
  if(bmsel>=0)
  {
    if(bmsel<edptop)edptop=bmsel;
    if(bmsel>=edptop+h)edptop=bmsel-h+1;
  }
  if(edptop>bmcount()-h)edptop=bmcount()-h;
  if(edptop<0)edptop=0;
  tuifill(0,y+1,w,h,' ',edpanec);
  for(i=0;i<h;i++)
  {
    li=edptop+i;
    if(li>=bmcount())break;
    a=edpanec;
    if(li==bmsel)
    {
      a=edpanesel;
      tuifill(0,y+1+i,w,1,' ',a);
    }
    tuitext(1,y+1+i,bmshow(li),a);
  }
  return 0;
}

/* the whole editor into the back grid, unflushed and without the caret: the
   menus and dialogs repaint it underneath themselves */
func edpaint()
{
  var w,h,rows,i,j,x,li,len,sel,a,nl:int;
  var p:*char;
  w=tuicols();
  h=tuirows();
  rows=edrows();
  mnbar(0-1);
  /* the file name at the right of the menu bar, if it fits */
  nl=strlen2(edname)+2;
  if(b.dirty)nl=nl+2;
  if(nl+34<w)
  {
    tuitext(w-nl,0,edname,edtitle);
    if(b.dirty)tuitext(w-4,0," *",edtitle);
  }
  sel=edselnorm();
  tuifill(0,1,w,rows,' ',edtext);
  for(i=0;i<rows;i++)
  {
    li=edtop+i;
    if(li>=b.n)continue;
    p=b.line(li);
    len=b.llen(li);
    x=0;
    for(j=edleft;j<=len;j++)
    {
      if(x>=w)break;
      a=edtext;
      if(sel&&edinsel(li,j))a=edblock;
      if(j<len)tuiput(x,1+i,p[j],a);
      else if(a==edblock)tuiput(x,1+i,' ',a);   /* a selected newline */
      x++;
    }
  }
  if(edpaneh())edpanedraw(1+rows,edpaneh());
  /* status bar: the position, then the message or the key hints */
  tuifill(0,h-1,w,1,' ',edstat);
  tuitext(1,h-1,"L",edstat);
  x=ednum(2,h-1,edcy+1,edstat);
  tuitext(x,h-1," C",edstat);
  ednum(x+2,h-1,edcx+1,edstat);
  if(edmsg)tuitext(14,h-1,edmsg,edstat);
  else tuitext(14,h-1,"F2 Save  F3 Open  F9 Build  F10 Menu  Alt-X Quit",edstat);
  return 0;
}

func eddraw()
{
  var rows:int;
  rows=edrows();
  edpaint();
  /* the caret, only when it is actually on screen */
  if((edcy>=edtop)&&(edcy<edtop+rows))tuicurs(edcx-edleft,1+edcy-edtop);
  else tuicurs(0-1,0);
  tuiflush();
  return 0;
}

/* a cursor-motion key moves the cursor and returns 1; anything else 0 */
func edmove(k:int)
{
  var rows:int;
  rows=edrows();
  if(k==K_LEFT)
  {
    if(edcx>0)edcx=edcx-1;
    else if(edcy>0){edcy=edcy-1;edcx=edlen();}
  }
  else if(k==K_RIGHT)
  {
    if(edcx<edlen())edcx=edcx+1;
    else if(edcy<b.n-1){edcy=edcy+1;edcx=0;}
  }
  else if(k==K_UP)edcy=edcy-1;
  else if(k==K_DOWN)edcy=edcy+1;
  else if(k==K_HOME)edcx=0;
  else if(k==K_END)edcx=edlen();
  else if(k==K_PGUP){edcy=edcy-rows;edtop=edtop-rows;}
  else if(k==K_PGDN){edcy=edcy+rows;edtop=edtop+rows;}
  else return 0;
  /* clamp now: a selection anchored after this must not sit off the text */
  if(edcy<0)edcy=0;
  if(edcy>=b.n)edcy=b.n-1;
  if(edcx>edlen())edcx=edlen();
  return 1;
}

/* the undo run a key belongs to: typing (Enter and Tab included),
   Backspace, Del, or EK_NONE for a key that does not edit */
func edkindof(k:int)
{
  if((k==K_ENTER)||(k==K_TAB)||((k>=32)&&(k<127)))return EK_TYPE;
  if(k==K_BS)return EK_BS;
  if(k==K_DEL)return EK_DEL;
  return EK_NONE;
}

/* delete the selected text, leaving the cursor where it started */
func eddelsel()
{
  var i,n:int;
  if(!edselnorm())
  {
    edsel=0;
    return 0;
  }
  if(edy0==edy1)
  {
    for(i=edx0;i<edx1;i++)b.delch(edy0,edx0);
  }
  else
  {
    n=b.llen(edy0)-edx0;
    for(i=0;i<n;i++)b.delch(edy0,edx0);
    for(i=edy0+1;i<edy1;i++)b.delline(edy0+1);
    for(i=0;i<edx1;i++)b.delch(edy0+1,0);
    b.join(edy0);
  }
  edcy=edy0;
  edcx=edx0;
  edsel=0;
  return 1;
}

/* copy the selection to the clipboard; 0 if nothing is selected */
func edcopysel()
{
  var y,x,n,from,to:int;
  var p:*char;
  if(!edselnorm())return 0;
  n=0;
  for(y=edy0;y<=edy1;y++)
  {
    from=0;
    to=b.llen(y);
    if(y==edy0)from=edx0;
    if(y==edy1)to=edx1;
    n=n+to-from;
    if(y<edy1)n++;
  }
  if(edclip)free(edclip);
  edclip=malloc(n+1);
  if(!edclip)
  {
    fprintf(stderr,"ed: out of memory\n");
    exit(2);
  }
  n=0;
  for(y=edy0;y<=edy1;y++)
  {
    p=b.line(y);
    from=0;
    to=b.llen(y);
    if(y==edy0)from=edx0;
    if(y==edy1)to=edx1;
    for(x=from;x<to;x++)edclip[n++]=p[x];
    if(y<edy1)edclip[n++]=10;
  }
  edclip[n]=0;
  return 1;
}

/* insert text at the cursor, which ends up after it */
func edinsert(s:*char)
{
  while(*s)
  {
    if(*s==10)
    {
      b.split(edcy,edcx);
      edcy=edcy+1;
      edcx=0;
    }
    else
    {
      b.insch(edcy,edcx,*s);
      edcx=edcx+1;
    }
    s++;
  }
  return 0;
}

/* search forward from the cursor for edfind; a match is selected with the
   cursor at its end, so searching again finds the next one */
func edsearch()
{
  var y,x,i,n,len:int;
  var p:*char;
  n=strlen2(edfind);
  if(!n)return 0;
  for(y=edcy;y<b.n;y++)
  {
    p=b.line(y);
    len=b.llen(y);
    x=0;
    if(y==edcy)x=edcx;
    while(x+n<=len)
    {
      for(i=0;i<n;i++)if(p[x+i]!=edfind[i])break;
      if(i==n)
      {
        edsel=1;
        edsy=y;
        edsx=x;
        edcy=y;
        edcx=x+n;
        return 1;
      }
      x++;
    }
  }
  edmsg="Search string not found";
  return 0;
}

/* the status message pre, the decimal n, post -- built in edmbuf */
func edfmt(pre:*char,n:int,post:*char):*char
{
  var [24]char:d;
  var i,j:int;
  j=0;
  while(*pre&&(j<40))edmbuf[j++]=*pre++;
  if(n<0)
  {
    edmbuf[j++]='-';
    n=0-n;
  }
  i=0;
  d[i++]='0'+n%10;
  n=n/10;
  while(n>0)
  {
    d[i++]='0'+n%10;
    n=n/10;
  }
  while(i>0)
  {
    i--;
    edmbuf[j++]=d[i];
  }
  while(*post&&(j<79))edmbuf[j++]=*post++;
  edmbuf[j]=0;
  return edmbuf;
}

/* Wait for one of keys (lower-case letters) or Esc, with the editor drawn
   and edmsg asking the question on the status line, so whatever it is
   about stays in view: the key, K_ESC, or -1 at end of input. */
func edprompt(keys:*char)
{
  var k,i:int;
  while(1)
  {
    edshow();
    eddraw();
    k=tuikey(0-1);
    if(k==K_NONE)continue;
    if(k==K_EOF)return 0-1;
    if(k==K_RESIZE)
    {
      tuiresize();
      continue;
    }
    if(k==K_ESC)return K_ESC;
    if((k>='A')&&(k<='Z'))k=k+32;
    for(i=0;keys[i];i++)
    if(keys[i]==k)return k;
  }
}

/* Replace edfind with edrepl from the cursor on. Each match is selected and
   Y replaces it, N skips it, A replaces it and every later one without
   asking, Esc stops; returns 1 if input ended (the editor exits). One undo
   step takes back the whole command. */
func edreploop()
{
  var k,all,cnt,found:int;
  if(!edfind[0])return 0;
  edlastrep=1;
  b.mark(edcy,edcx);
  all=0;
  cnt=0;
  found=0;
  while(edsearch())
  {
    found=1;
    if(!all)
    {
      edmsg="Replace this occurrence?  Y Yes  N No  A All  Esc Stop";
      k=edprompt("yna");
      if(k<0)return edeof();
      if(k==K_ESC)break;
      if(k=='n')continue;
      if(k=='a')all=1;
    }
    eddelsel();
    edinsert(edrepl);
    cnt++;
  }
  edsel=0;
  if(!found)return 0;            /* edsearch said it was not found */
  if(cnt==1)edmsg="1 occurrence replaced";
  else edmsg=edfmt("",cnt," occurrences replaced");
  return 0;
}

func edeq(a:*char,c:*char)
{
  while(*a&&(*a==*c))
  {
    a++;
    c++;
  }
  return *a==*c;
}

/* do two paths name the same file (both resolved when they exist) */
func edsame(a:*char,c:*char)
{
  var ra,rc:*char;
  var r:int;
  ra=realpath(a,0);
  rc=realpath(c,0);
  if(ra&&rc)r=edeq(ra,rc);
  else r=edeq(a,c);
  if(ra)free(ra);
  if(rc)free(rc);
  return r;
}

/* End of input: no more keys can come, so keep the edits with the same
   atomic save F2 uses; a failure is reported after the terminal is back. */
func edeof()
{
  if(b.dirty&&!b.save(edname))edrc=1;
  return 1;
}

/* Before the buffer is replaced: 1 to go ahead, 0 to stay, -1 at end of
   input. A modified buffer asks first; Y saves, N discards. */
func edleave()
{
  var k:int;
  if(!b.dirty)return 1;
  k=dlgask("Open","The file has unsaved changes. Save it first?",
  "Y Yes  N No  Esc Cancel","yn");
  if(k<0)return 0-1;
  if(k=='n')return 1;
  if(k!='y')return 0;
  if(b.save(edname))return 1;
  edmsg="SAVE FAILED";
  return 0;
}

/* make nm the edited file. A missing path starts a new document; a path
   that exists but cannot be read is an error and the buffer stays. */
func edload(nm:*char)
{
  if(!b.load(nm))
  {
    if(bfexists(nm))
    {
      dlgask("Error","Cannot load that file.","Press any key","");
      return 0;
    }
    b.done();
    b.init();
  }
  if(edowned)free(edname);
  edname=eddup(nm);
  edowned=1;
  edcy=0;edcx=0;edtop=0;edleft=0;edsel=0;
  return 1;
}

/* go to message i's location, opening its file when it is another one */
func edjump(i:int)
{
  var r:int;
  if(i<0)
  {
    edmsg="No more messages";
    return 0;
  }
  edpane=1;
  if(!edsame(bmfile[i],edname))
  {
    r=edleave();
    if(r<0)return edeof();
    if(!r)return 0;
    if(!edload(bmfile[i]))return 0;
  }
  edsel=0;
  edcy=bmline[i]-1;
  edcx=0;
  /* langc's caret column, if the line it echoed is still the line here */
  if((bmcol[i]>=0)&&edeq(bmtext[i+1],b.line(edcy)))edcx=bmcol[i];
  edmsg=bmshow(i);
  return 0;
}

/* F9: save, build, and land on the first error */
func edbuild()
{
  var rc:int;
  edsel=0;
  if(b.dirty&&!b.save(edname))
  {
    edmsg="SAVE FAILED";
    return 0;
  }
  edmsg="Building...";
  eddraw();
  rc=bdrun(edname);
  edpane=1;
  edptop=0;
  if(rc==0)
  {
    edmsg="Build OK";
    return 0;
  }
  edmsg="Build failed";
  if(bmnext(1)>=0)return edjump(bmsel);
  return 0;
}

/* run one command; returns 1 when the editor should exit */
func edcmd(c:int)
{
  var [ED_PATH]char:path;
  var r,n,i:int;
  edkind=EK_NONE;           /* a command is an undo step of its own */
  if(c<0)return edeof();
  if(c==CM_EXIT)return edquitreq();
  if(c==CM_SAVE)
  {
    if(b.save(edname))edmsg="saved";
    else edmsg="SAVE FAILED";
  }
  else if(c==CM_SAVEAS)
  {
    edcopy(path,edname,ED_PATH);
    r=dlgline("Save As","Save the file as",path,ED_PATH);
    if(r<0)return edeof();
    if(r&&path[0])
    {
      if(b.save(path))
      {
        if(edowned)free(edname);
        edname=eddup(path);
        edowned=1;
        edmsg="saved";
      }
      else edmsg="SAVE FAILED";
    }
  }
  else if(c==CM_OPEN)
  {
    r=edleave();
    if(r<0)return edeof();
    if(!r)return 0;
    path[0]=0;
    r=dlgline("Open","File to open",path,ED_PATH);
    if(r<0)return edeof();
    if(r&&path[0])edload(path);
  }
  else if(c==CM_CUT)
  {
    if(edcopysel())
    {
      b.mark(edcy,edcx);
      eddelsel();
    }
  }
  else if(c==CM_COPY)edcopysel();
  else if(c==CM_PASTE)
  {
    if(edclip)
    {
      b.mark(edcy,edcx);
      eddelsel();
      edinsert(edclip);
    }
  }
  else if(c==CM_CLEAR)
  {
    b.mark(edcy,edcx);
    eddelsel();
  }
  else if((c==CM_UNDO)||(c==CM_REDO))
  {
    if(c==CM_UNDO)r=b.undo();
    else r=b.redo();
    if(r)
    {
      edsel=0;
      edcy=b.uy;
      edcx=b.ux;
    }
    else if(c==CM_UNDO)edmsg="Nothing to undo";
    else edmsg="Nothing to redo";
  }
  else if((c==CM_FIND)||((c==CM_AGAIN)&&!edfind[0]))
  {
    r=dlgline("Find","Text to find",edfind,ED_FIND);
    if(r<0)return edeof();
    if(r)
    {
      edlastrep=0;
      edsearch();
    }
  }
  else if(c==CM_REPLACE)
  {
    r=dlgline("Replace","Text to find",edfind,ED_FIND);
    if(r<0)return edeof();
    if(!r)return 0;
    r=dlgline("Replace","New text",edrepl,ED_FIND);
    if(r<0)return edeof();
    if(r)return edreploop();
  }
  else if((c==CM_AGAIN)&&edlastrep)return edreploop();
  else if(c==CM_AGAIN)edsearch();
  else if(c==CM_GOTO)
  {
    path[0]=0;
    r=dlgline("Go to Line","Line number",path,ED_PATH);
    if(r<0)return edeof();
    if(r)
    {
      n=0;
      for(i=0;(path[i]>='0')&&(path[i]<='9');i++)n=n*10+path[i]-'0';
      if(n<1)n=1;
      edsel=0;
      edcy=n-1;
      edcx=0;
    }
  }
  else if(c==CM_BUILD)return edbuild();
  else if(c==CM_NEXTERR)return edjump(bmnext(1));
  else if(c==CM_PREVERR)return edjump(bmnext(0-1));
  else if(c==CM_MSGS)edpane=!edpane;
  return 0;
}

/* Alt-X or File/Exit: quit at once if the buffer is clean, else ask on the
   status bar (F2 saves, Alt-X again discards, Esc cancels) */
func edquitreq()
{
  if(!b.dirty)return 1;
  edquit=1;
  edmsg="F2 Save  Alt-X Discard  Esc Cancel";
  return 0;
}

/* one key; returns 1 when the editor should exit */
func edkey(k:int)
{
  var m,base,kind:int;
  if(k==K_RESIZE){tuiresize();return 0;}
  if(k==K_EOF)return edeof();
  if(edquit)
  {
    if(edisquit(k))return 1;
    if(k==K_ESC){edquit=0;edmsg=0;return 0;}
    if(k==K_F2)
    {
      if(b.save(edname)){edquit=0;edmsg="saved";}
      else edmsg="SAVE FAILED  Alt-X Discard  Esc Cancel";
    }
    return 0;
  }
  edmsg=0;
  kind=edkindof(k);
  if(!kind)edkind=EK_NONE;  /* any other key ends a run of typing */
  if(edisquit(k))return edquitreq();
  if(k==K_F10)return edcmd(mnrun(0));
  if(k==K_ALT+K_BS)return edcmd(CM_UNDO);
  if((k>K_ALT)&&(k<K_ALT+256))
  {
    m=mnfind(k-K_ALT);
    if(m>=0)return edcmd(mnrun(m));
    return 0;
  }
  if(k==K_F2)return edcmd(CM_SAVE);
  if(k==K_F3)return edcmd(CM_OPEN);
  if(k==K_F9)return edcmd(CM_BUILD);
  if(k==K_ALT+K_F8)return edcmd(CM_NEXTERR);
  if(k==K_ALT+K_F7)return edcmd(CM_PREVERR);
  if(k==12)return edcmd(CM_AGAIN);            /* Ctrl-L */
  if(k==K_SHIFT+K_DEL)return edcmd(CM_CUT);
  if(k==K_CTRL+K_INS)return edcmd(CM_COPY);
  if(k==K_SHIFT+K_INS)return edcmd(CM_PASTE);
  if(k==K_CTRL+K_DEL)return edcmd(CM_CLEAR);
  if(k==K_ESC)
  {
    if(edsel)edsel=0;
    else edpane=0;
    return 0;
  }
  /* Shift+motion extends the selection from where it started */
  base=k-K_SHIFT;
  if((base>=K_UP)&&(base<=K_PGDN))
  {
    if(!edsel)
    {
      edsel=1;
      edsy=edcy;
      edsx=edcx;
    }
    edmove(base);
    return 0;
  }
  if(edmove(k))
  {
    edsel=0;
    return 0;
  }
  if(!kind)return 0;
  /* an editing key starts a new undo step unless it continues a run of its
     own kind; replacing a selection always starts one */
  if((kind!=edkind)||edselnorm())b.mark(edcy,edcx);
  edkind=kind;
  if(k==K_ENTER)edkind=EK_NONE;   /* each typed line undoes on its own */
  if((k==K_BS)||(k==K_DEL))
  {
    if(edsel&&eddelsel())return 0;
    edsel=0;
  }
  if(k==K_BS)
  {
    if(edcx>0)
    {
      b.delch(edcy,edcx-1);
      edcx=edcx-1;
    }
    else if(edcy>0)
    {
      edcx=b.llen(edcy-1);
      b.join(edcy-1);
      edcy=edcy-1;
    }
    return 0;
  }
  if(k==K_DEL)
  {
    if(edcx<edlen())b.delch(edcy,edcx);
    else if(edcy<b.n-1)b.join(edcy);
    return 0;
  }
  if((k==K_ENTER)||(k==K_TAB)||((k>=32)&&(k<127)))eddelsel();
  if(k==K_ENTER)
  {
    b.split(edcy,edcx);
    edcy=edcy+1;
    edcx=0;
    return 0;
  }
  if(k==K_TAB)
  {
    /* a tab enters two spaces: the compositor draws only printable bytes,
       and two spaces is the canonical indent uplncfmt produces */
    b.insch(edcy,edcx,' ');edcx=edcx+1;
    b.insch(edcy,edcx,' ');edcx=edcx+1;
    return 0;
  }
  if((k>=32)&&(k<127))
  {
    b.insch(edcy,edcx,k);
    edcx=edcx+1;
    return 0;
  }
  return 0;
}

func edmenus()
{
  mninit();
  mnbegin("~F~ile");
  mnitem("~O~pen...","F3",CM_OPEN);
  mnitem("~S~ave","F2",CM_SAVE);
  mnitem("Save ~a~s...","",CM_SAVEAS);
  mnitem(0,"",0);
  mnitem("E~x~it","Alt-X",CM_EXIT);
  mnbegin("~E~dit");
  mnitem("~U~ndo","Alt-BkSp",CM_UNDO);
  mnitem("~R~edo","",CM_REDO);
  mnitem(0,"",0);
  mnitem("Cu~t~","Shift-Del",CM_CUT);
  mnitem("~C~opy","Ctrl-Ins",CM_COPY);
  mnitem("~P~aste","Shift-Ins",CM_PASTE);
  mnitem("C~l~ear","Ctrl-Del",CM_CLEAR);
  mnbegin("~S~earch");
  mnitem("~F~ind...","",CM_FIND);
  mnitem("~R~eplace...","",CM_REPLACE);
  mnitem("~S~earch again","Ctrl-L",CM_AGAIN);
  mnitem("~G~o to line...","",CM_GOTO);
  mnitem(0,"",0);
  mnitem("~P~revious error","Alt-F7",CM_PREVERR);
  mnitem("~N~ext error","Alt-F8",CM_NEXTERR);
  mnbegin("~C~ompile");
  mnitem("~B~uild","F9",CM_BUILD);
  mnitem("~M~essages","",CM_MSGS);
  return 0;
}

func main(argc:int,argv:**char)
{
  var k:int;
  if(argc<2)
  {
    fprintf(stderr,"usage: ed <file>\n");
    return 2;
  }
  edname=argv[1];
  edowned=0;
  edtitle=C_BLACK+C_WHITE*16;
  edtext=C_BWHITE+C_BLUE*16;
  edstat=C_BLACK+C_WHITE*16;
  edblock=C_BLUE+C_WHITE*16;
  edpanec=C_BLACK+C_CYAN*16;
  edpanesel=C_BWHITE+C_GREEN*16;
  b.init();
  /* A missing path starts a new document. Any path that exists but cannot be
     read is an error, never an empty document that could later overwrite it. */
  if(!b.load(edname)&&bfexists(edname))
  {
    fprintf(stderr,"ed: cannot load %s\n",edname);
    b.done();
    return 2;
  }
  edcy=0;edcx=0;edtop=0;edleft=0;edmsg=0;edquit=0;edrc=0;
  edsel=0;edclip=0;edfind[0]=0;edpane=0;edptop=0;edkind=EK_NONE;
  edrepl[0]=0;edlastrep=0;
  bmsel=0-1;
  edmenus();
  if(tuiinit())return 2;
  edshow();
  eddraw();
  while(1)
  {
    k=tuikey(0-1);
    if(k==K_NONE)continue;
    if(edkey(k))break;
    edshow();
    eddraw();
  }
  tuidone();
  if(edrc)fprintf(stderr,"ed: cannot save changes to %s\n",edname);
  b.done();
  if(edclip)free(edclip);
  if(edowned)free(edname);
  return edrc;
}
