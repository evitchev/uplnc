/* menu.e: the IDE's menu bar, pull-down menus, and modal dialogs (IDE.md
   phase 1). The editor declares its menus once with mnbegin/mnitem and runs
   one with mnrun, which returns the chosen command; dlgline asks for a line
   of text and dlgask for one key out of a few.

   Every modal loop here repaints the editor underneath through edpaint()
   before drawing itself, so a resize, or a dialog closing, never leaves
   stale cells behind.

   A label marks its hotkey with tildes: "~O~pen..." draws the O in the
   hotkey colour, and pressing o while that menu is open picks it. A menu
   title's hotkey with Alt (Alt-F for "~F~ile") opens it from anywhere. */

#include "tui.he"

func tuiresize();
func tuicols();
func tuirows();
func tuiput(x:int,y:int,c:int,attr:int);
func tuitext(x:int,y:int,s:*char,attr:int);
func tuifill(x:int,y:int,w:int,h:int,c:int,attr:int);
func tuibox(x:int,y:int,w:int,h:int,attr:int);
func tuishadow(x:int,y:int,w:int,h:int);
func tuiflush();
func tuicurs(x:int,y:int);
func tuikey(ms:int);
func edpaint();          /* ed.e: the whole editor, unflushed, no caret */

#define MN_MENUS 8
#define MN_ITEMS 64

var mntitle:[MN_MENUS]*char;
var mnfirst:[MN_MENUS]int; /* each menu's first item */
var mncnt:[MN_MENUS]int;   /* ... and how many it has */
var mnx:[MN_MENUS]int;     /* where each title sits on the bar */
var mnn:int;
var milabel:[MN_ITEMS]*char; /* 0 for a separator line */
var mikey:[MN_ITEMS]*char;   /* the shortcut shown on the right, or "" */
var micmd:[MN_ITEMS]int;
var mitems:int;
var mnbarc,mnhotc,mnselc,mnselhot:int;
var dlgc,dlgfield,dlgfsel:int;

func mninit()
{
  mnn=0;
  mitems=0;
  /* Turbo C++: black on grey, red hotkeys, the selection on green */
  mnbarc=C_BLACK+C_WHITE*16;
  mnhotc=C_RED+C_WHITE*16;
  mnselc=C_BLACK+C_GREEN*16;
  mnselhot=C_RED+C_GREEN*16;
  dlgc=C_BLACK+C_WHITE*16;
  dlgfield=C_BWHITE+C_BLUE*16;
  dlgfsel=C_BWHITE+C_GREEN*16;
  return 0;
}

/* start a new pull-down menu titled t */
func mnbegin(t:*char)
{
  if(mnn>=MN_MENUS)return 0;
  mntitle[mnn]=t;
  mnfirst[mnn]=mitems;
  mncnt[mnn]=0;
  mnn++;
  return 0;
}

/* add an item to the newest menu; a 0 label is a separator */
func mnitem(label:*char,key:*char,cmd:int)
{
  if((mnn<1)||(mitems>=MN_ITEMS))return 0;
  milabel[mitems]=label;
  mikey[mitems]=key;
  micmd[mitems]=cmd;
  mitems++;
  mncnt[mnn-1]=mncnt[mnn-1]+1;
  return 0;
}

func mnstrlen(s:*char)
{
  var n:int;
  n=0;
  while(s[n])n++;
  return n;
}

/* the width a label occupies on screen (its tildes take none) */
func mnlen(s:*char)
{
  var n:int;
  n=0;
  while(*s)
  {
    if(*s!='~')n++;
    s++;
  }
  return n;
}

/* a label's hotkey, lower-cased, or 0 */
func mnhot(s:*char)
{
  while(*s&&(*s!='~'))s++;
  if(!*s)return 0;
  s++;
  if((*s>='A')&&(*s<='Z'))return *s+32;
  return *s;
}

/* draw a label: plain text in attr, the ~marked~ part in hot; the end x */
func mnlabel(x:int,y:int,s:*char,attr:int,hot:int)
{
  var on:int;
  on=0;
  while(*s)
  {
    if(*s=='~')on=!on;
    else
    {
      if(on)tuiput(x,y,*s,hot);
      else tuiput(x,y,*s,attr);
      x++;
    }
    s++;
  }
  return x;
}

/* the menu whose title hotkey is c, or -1 */
func mnfind(c:int)
{
  var i:int;
  if((c>='A')&&(c<='Z'))c=c+32;
  for(i=0;i<mnn;i++)
  if(mnhot(mntitle[i])==c)return i;
  return 0-1;
}

/* the menu bar on row 0, menu `open` highlighted (-1 for none) */
func mnbar(open:int)
{
  var i,x:int;
  tuifill(0,0,tuicols(),1,' ',mnbarc);
  x=1;
  for(i=0;i<mnn;i++)
  {
    mnx[i]=x;
    if(i==open)
    {
      tuifill(x,0,mnlen(mntitle[i])+2,1,' ',mnselc);
      mnlabel(x+1,0,mntitle[i],mnselc,mnselhot);
    }
    else mnlabel(x+1,0,mntitle[i],mnbarc,mnhotc);
    x=x+mnlen(mntitle[i])+2;
  }
  return 0;
}

/* the inner width of menu m: a space, the widest label, three spaces and
   the widest shortcut if any item has one, and a space */
func mnwidth(m:int)
{
  var i,lw,kw:int;
  lw=kw=0;
  for(i=mnfirst[m];i<mnfirst[m]+mncnt[m];i++)
  {
    if(!milabel[i])continue;
    if(mnlen(milabel[i])>lw)lw=mnlen(milabel[i]);
    if(mnstrlen(mikey[i])>kw)kw=mnstrlen(mikey[i]);
  }
  if(kw)return lw+kw+5;
  return lw+2;
}

/* the first item of menu m that is not a separator, as an offset */
func mnfirstsel(m:int)
{
  var r:int;
  for(r=0;r<mncnt[m];r++)
  if(milabel[mnfirst[m]+r])return r;
  return 0;
}

/* the next selectable item from sel in direction d, wrapping around */
func mnstep(m:int,sel:int,d:int)
{
  var r,i:int;
  r=sel;
  for(i=0;i<mncnt[m];i++)
  {
    r=(r+d+mncnt[m])%mncnt[m];
    if(milabel[mnfirst[m]+r])return r;
  }
  return sel;
}

/* menu m pulled down under its title, item sel highlighted */
func mndrop(m:int,sel:int)
{
  var x,y,w,h,i,r,a,ha:int;
  w=mnwidth(m)+2;
  h=mncnt[m]+2;
  x=mnx[m]-1;
  if(x+w+2>tuicols())x=tuicols()-w-2;
  if(x<0)x=0;
  y=1;
  tuifill(x,y,w,h,' ',mnbarc);
  tuibox(x,y,w,h,mnbarc);
  for(r=0;r<mncnt[m];r++)
  {
    i=mnfirst[m]+r;
    if(!milabel[i])
    {
      tuifill(x+1,y+1+r,w-2,1,ACS_HLINE,mnbarc+A_ACS);
      tuiput(x,y+1+r,ACS_LTEE,mnbarc+A_ACS);
      tuiput(x+w-1,y+1+r,ACS_RTEE,mnbarc+A_ACS);
      continue;
    }
    a=mnbarc;
    ha=mnhotc;
    if(r==sel)
    {
      a=mnselc;
      ha=mnselhot;
      tuifill(x+1,y+1+r,w-2,1,' ',a);
    }
    mnlabel(x+2,y+1+r,milabel[i],a,ha);
    if(mikey[i][0])tuitext(x+w-2-mnstrlen(mikey[i]),y+1+r,mikey[i],a);
  }
  tuishadow(x+w,y+1,2,h);
  tuishadow(x+2,y+h,w,1);
  return 0;
}

/* Run menu m: Up/Down move, Left/Right or Alt+title switch menus, Enter or
   an item's hotkey picks, Esc or F10 closes. The chosen command, 0 for
   none, or -1 at end of input. */
func mnrun(m:int)
{
  var sel,k,r,i:int;
  if((m<0)||(m>=mnn))return 0;
  sel=mnfirstsel(m);
  while(1)
  {
    edpaint();
    mnbar(m);
    mndrop(m,sel);
    tuicurs(0-1,0);
    tuiflush();
    k=tuikey(0-1);
    if(k==K_NONE)continue;
    if(k==K_EOF)return 0-1;
    if(k==K_RESIZE)
    {
      tuiresize();
      continue;
    }
    if((k==K_ESC)||(k==K_F10))return 0;
    if((k==K_LEFT)||(k==K_RIGHT))
    {
      if(k==K_LEFT)m=(m+mnn-1)%mnn;
      else m=(m+1)%mnn;
      sel=mnfirstsel(m);
      continue;
    }
    if(k==K_UP)sel=mnstep(m,sel,0-1);
    else if(k==K_DOWN)sel=mnstep(m,sel,1);
    else if(k==K_ENTER)return micmd[mnfirst[m]+sel];
    else if((k>K_ALT)&&(k<K_ALT+256))
    {
      i=mnfind(k-K_ALT);
      if(i>=0)
      {
        m=i;
        sel=mnfirstsel(m);
      }
    }
    else if((k>=32)&&(k<127))
    {
      if((k>='A')&&(k<='Z'))k=k+32;
      for(r=0;r<mncnt[m];r++)
      {
        i=mnfirst[m]+r;
        if(milabel[i]&&(mnhot(milabel[i])==k))return micmd[i];
      }
    }
  }
}

/* a centred dialog box with inner size w x h, titled t, drawn over the
   editor; the top-left inner cell comes back through px, py */
func dlgframe(t:*char,w:int,h:int,px:*int,py:*int)
{
  var x,y,tl:int;
  x=(tuicols()-w-2)/2;
  y=(tuirows()-h-2)/2;
  if(x<0)x=0;
  if(y<0)y=0;
  tuifill(x,y,w+2,h+2,' ',dlgc);
  tuibox(x,y,w+2,h+2,dlgc);
  tl=mnstrlen(t);
  tuiput(x+(w-tl)/2,y,' ',dlgc);
  tuitext(x+(w-tl)/2+1,y,t,dlgc);
  tuiput(x+(w-tl)/2+tl+1,y,' ',dlgc);
  tuishadow(x+w+2,y+1,2,h+2);
  tuishadow(x+2,y+h+2,w+2,1);
  *px=x+1;
  *py=y+1;
  return 0;
}

/* Ask for one line of text: a prompt over an input field that starts with
   buf's text. Enter stores the edit in buf (cap bytes with the NUL) and
   returns 1; Esc returns 0 and leaves buf alone; end of input returns -1.
   As in Turbo, the starting text is selected: typing replaces it and
   Backspace clears it, while an arrow key keeps it for editing. */
func dlgline(t:*char,prompt:*char,buf:*char,cap:int)
{
  var [256]char:s;
  var n,k,x,y,w,i,off,fresh,a:int;
  if(cap>256)cap=256;
  n=0;
  while(buf[n]&&(n<cap-1))
  {
    s[n]=buf[n];
    n++;
  }
  s[n]=0;
  fresh=n>0;
  while(1)
  {
    w=56;
    if(w>tuicols()-6)w=tuicols()-6;
    if(w<10)w=10;
    edpaint();
    dlgframe(t,w+2,3,&x,&y);
    tuitext(x+1,y,prompt,dlgc);
    tuifill(x+1,y+1,w,1,' ',dlgfield);
    off=0;
    if(n>w-1)off=n-(w-1);   /* keep the end of the text and the caret in view */
    a=dlgfield;
    if(fresh)a=dlgfsel;
    for(i=off;i<n;i++)tuiput(x+1+i-off,y+1,s[i],a);
    tuitext(x+1,y+2,"Enter OK  Esc Cancel",dlgc);
    tuicurs(x+1+n-off,y+1);
    tuiflush();
    k=tuikey(0-1);
    if(k==K_NONE)continue;
    if(k==K_EOF)return 0-1;
    if(k==K_RESIZE)tuiresize();
    else if(k==K_ESC)return 0;
    else if(k==K_ENTER)
    {
      for(i=0;i<=n;i++)buf[i]=s[i];
      return 1;
    }
    else if(k==K_BS)
    {
      if(fresh)n=0;
      else if(n>0)n--;
      s[n]=0;
      fresh=0;
    }
    else if((k>=32)&&(k<127))
    {
      if(fresh)n=0;
      fresh=0;
      if(n<cap-1)s[n++]=k;
      s[n]=0;
    }
    else fresh=0;
  }
}

/* A message box: text over a hint line. Returns the first key pressed that
   is one of `keys` (lower-case letters), K_ESC, or -1 at end of input; with
   an empty `keys`, any key closes it and comes back. */
func dlgask(t:*char,text:*char,hint:*char,keys:*char)
{
  var k,x,y,w,i:int;
  while(1)
  {
    w=mnstrlen(text);
    if(mnstrlen(hint)>w)w=mnstrlen(hint);
    if(mnstrlen(t)+2>w)w=mnstrlen(t)+2;
    w=w+2;
    edpaint();
    dlgframe(t,w,3,&x,&y);
    tuitext(x+1,y,text,dlgc);
    tuitext(x+1,y+2,hint,dlgc);
    tuicurs(0-1,0);
    tuiflush();
    k=tuikey(0-1);
    if(k==K_NONE)continue;
    if(k==K_EOF)return 0-1;
    if(k==K_RESIZE)
    {
      tuiresize();
      continue;
    }
    if(!keys[0])return k;
    if(k==K_ESC)return K_ESC;
    if((k>='A')&&(k<='Z'))k=k+32;
    for(i=0;keys[i];i++)
    if(keys[i]==k)return k;
  }
}
