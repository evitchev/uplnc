/* ed.e: the IDE's editor window (IDE.md phase 1, slice 1a) -- a Turbo-blue
   frame, one text buffer, cursor motion, editing, scrolling, and save.

   Keys: arrows/Home/End/PgUp/PgDn move, printable keys and Enter/Backspace/
   Del edit (Tab enters two spaces), F2 saves, and Alt-X or F10 quits --
   Alt-X first, because terminal emulators often capture F10 for themselves.

   Layout: row 0 is the title bar, row h-1 the status bar, and the rows
   between are the text viewport. The viewport origin (edtop, edleft) follows
   the cursor: edshow() is the single place that decides what is visible, so
   every key handler only has to move the cursor.

   Build: perl src/langdrv.pl -o ed ide/ed.e ide/buf.e ide/tui.e ide/tshim.c */

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
func exit(c:int);
var extern stderr:*int;

var b:sbuf;
var edcy,edcx:int;         /* cursor: buffer line, column */
var edtop,edleft:int;      /* viewport origin */
var edname:*char;
var edmsg:*char;           /* transient status text */
var edtitle,edtext,edstat:int;
var edquit,edrc:int;       /* dirty-quit confirmation and process status */

func edrows(){return tuirows()-2;}   /* text rows between the two bars */

/* Turbo's own exit binding is Alt-X, and it is the one that always reaches us:
   terminal emulators commonly bind F10 themselves (MATE Terminal opens its
   menu bar with it), so F10 alone would strand the user. */
func edisquit(k:int)
{
  return (k==K_F10)||(k==K_ALT+'x');
}

func edlen(){return b.llen(edcy);}

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

func eddraw()
{
  var w,h,rows,i,j,x,li:int;
  var p:*char;
  w=tuicols();
  h=tuirows();
  rows=edrows();
  /* title bar */
  tuifill(0,0,w,1,' ',edtitle);
  tuitext(1,0,"UPLNC IDE",edtitle);
  tuitext(11,0,edname,edtitle);
  if(b.dirty)tuitext(11+strlen2(edname),0," *",edtitle);
  /* text */
  tuifill(0,1,w,rows,' ',edtext);
  for(i=0;i<rows;i++)
  {
    li=edtop+i;
    if(li>=b.n)continue;
    p=b.line(li);
    x=0;
    for(j=edleft;j<b.llen(li);j++)
    {
      if(x>=w)break;
      tuiput(x,1+i,p[j],edtext);
      x++;
    }
  }
  /* status bar */
  tuifill(0,h-1,w,1,' ',edstat);
  tuitext(1,h-1,"L",edstat);
  x=ednum(2,h-1,edcy+1,edstat);
  tuitext(x,h-1," C",edstat);
  ednum(x+2,h-1,edcx+1,edstat);
  tuitext(20,h-1,"F2 Save  Alt-X Quit",edstat);
  if(edmsg)tuitext(42,h-1,edmsg,edstat);
  /* the caret, only when it is actually on screen */
  if((edcy>=edtop)&&(edcy<edtop+rows))tuicurs(edcx-edleft,1+edcy-edtop);
  else tuicurs(0-1,0);
  tuiflush();
  return 0;
}

func strlen2(s:*char)
{
  var i:int;
  i=0;
  while(s[i])i++;
  return i;
}

/* one key; returns 1 when the editor should exit */
func edkey(k:int)
{
  var rows:int;
  rows=edrows();
  if(k==K_RESIZE){tuiresize();return 0;}
  /* No more input can arrive after EOF, so preserve edits with the same atomic
     save F2 uses. A failure is reported after the terminal is restored. */
  if(k==K_EOF)
  {
    if(b.dirty&&!b.save(edname))edrc=1;
    return 1;
  }
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
  if(edisquit(k))
  {
    if(!b.dirty)return 1;
    edquit=1;
    edmsg="F2 Save  Alt-X Discard  Esc Cancel";
    return 0;
  }
  if(k==K_F2)
  {
    if(b.save(edname))edmsg="saved";
    else edmsg="SAVE FAILED";
    return 0;
  }
  if(k==K_LEFT)
  {
    if(edcx>0)edcx=edcx-1;
    else if(edcy>0){edcy=edcy-1;edcx=edlen();}
    return 0;
  }
  if(k==K_RIGHT)
  {
    if(edcx<edlen())edcx=edcx+1;
    else if(edcy<b.n-1){edcy=edcy+1;edcx=0;}
    return 0;
  }
  if(k==K_UP){edcy=edcy-1;return 0;}
  if(k==K_DOWN){edcy=edcy+1;return 0;}
  if(k==K_HOME){edcx=0;return 0;}
  if(k==K_END){edcx=edlen();return 0;}
  if(k==K_PGUP){edcy=edcy-rows;edtop=edtop-rows;return 0;}
  if(k==K_PGDN){edcy=edcy+rows;edtop=edtop+rows;return 0;}
  if(k==K_ENTER)
  {
    b.split(edcy,edcx);
    edcy=edcy+1;
    edcx=0;
    return 0;
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

func main(argc:int,argv:**char)
{
  var k:int;
  if(argc<2)
  {
    fprintf(stderr,"usage: ed <file>\n");
    return 2;
  }
  edname=argv[1];
  edtitle=C_BLACK+C_CYAN*16;
  edtext=C_BWHITE+C_BLUE*16;
  edstat=C_BLACK+C_CYAN*16;
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
  return edrc;
}
