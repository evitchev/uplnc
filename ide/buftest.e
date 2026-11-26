/* buftest.e: the text buffer's cross-target proof. Exercises every editing
   primitive plus a save/load round trip through a real file, and checks the
   resulting text byte for byte; then undo and redo of every primitive, by
   group, with the cursors they report and the saved state they track. Pure
   logic and file I/O -- no terminal -- so it runs on every backend.

   Usage: buftest <scratch-file>   (exit 42 on success, else the failing step)
   Build: perl src/langdrv.pl -march=ARCH -o buftest ide/buftest.e ide/buf.e */

#include "buf.he"

var b:sbuf;

func streq0(a:*char,c:*char)
{
  var i:int;
  i=0;
  while(a[i]&&c[i])
  {
    if(a[i]!=c[i])return 0;
    i++;
  }
  return a[i]==c[i];
}

/* line i of the buffer equals want? */
func lineis(i:int,want:*char)
{
  var p:*char;
  p=b.line(i);
  if(!streq0(p,want))return 0;
  if(b.llen(i)!=strlen1(want))return 0;
  return 1;
}

/* the whole buffer, its lines joined by newlines, equals want? */
func textis(want:*char)
{
  var i,j,k:int;
  var p:*char;
  k=0;
  for(i=0;i<b.n;i++)
  {
    if(i>0)
    {
      if(want[k]!=10)return 0;
      k++;
    }
    p=b.line(i);
    for(j=0;j<b.llen(i);j++)
    {
      if(want[k]!=p[j])return 0;
      k++;
    }
  }
  return want[k]==0;
}

/* undo (d=0) or redo (d=1) one group: it must land on text with the cursor
   at y,x */
func step(d:int,text:*char,y:int,x:int)
{
  var r:int;
  if(d)r=b.redo();
  else r=b.undo();
  if(!r)return 0;
  if(!textis(text))return 0;
  return (b.uy==y)&&(b.ux==x);
}

func strlen1(s:*char)
{
  var i:int;
  i=0;
  while(s[i])i++;
  return i;
}

/* type the bytes of s into line i starting at column col */
func typein(i:int,col:int,s:*char)
{
  var j:int;
  j=0;
  while(s[j])
  {
    b.insch(i,col+j,s[j]);
    j++;
  }
  return 0;
}

func main(argc:int,argv:**char)
{
  var path:*char;
  var i:int;      /* plain braces are not a name scope in v0, so one `i` */
  if(argc<2)return 1;
  path=argv[1];
  /* run_tests uses this mode under RLIMIT_FSIZE: the attempted save must never
     truncate the already-existing destination before all output succeeds */
  if((argc>2)&&streq0(argv[2],"savefail"))
  {
    b.init();
    typein(0,0,"replacement");
    if(b.save(path))return 39;
    return 40;
  }
  b.init();

  /* a fresh buffer is one empty line */
  if(b.n!=1)return 2;
  if(!lineis(0,""))return 3;

  /* insert characters */
  typein(0,0,"hello");
  if(!lineis(0,"hello"))return 4;
  b.insch(0,0,'>');
  if(!lineis(0,">hello"))return 5;

  /* out-of-range edits are no-ops, not corruption */
  b.insch(0,99,'x');
  b.insch(9,0,'x');
  b.delch(0,99);
  b.delch(9,0);
  if(!lineis(0,">hello"))return 6;
  if(b.n!=1)return 7;

  /* delete characters */
  b.delch(0,0);
  if(!lineis(0,"hello"))return 8;

  /* split (Enter) in the middle, then at both edges */
  b.split(0,2);
  if(b.n!=2)return 9;
  if(!lineis(0,"he"))return 10;
  if(!lineis(1,"llo"))return 11;
  b.split(1,0);
  if((b.n!=3)||!lineis(1,"")||!lineis(2,"llo"))return 12;
  b.join(1);
  if((b.n!=2)||!lineis(1,"llo"))return 13;

  /* join (Backspace at column 0) */
  b.join(0);
  if(b.n!=1)return 14;
  if(!lineis(0,"hello"))return 15;

  /* insert and delete whole lines */
  b.insline(0);
  typein(0,0,"first");
  b.insline(2);
  typein(2,0,"third");
  if(b.n!=3)return 16;
  if(!lineis(0,"first")||!lineis(1,"hello")||!lineis(2,"third"))return 17;
  b.delline(1);
  if((b.n!=2)||!lineis(0,"first")||!lineis(1,"third"))return 18;

  /* the last line is emptied, never removed */
  b.delline(0);
  b.delline(0);
  if((b.n!=1)||!lineis(0,""))return 19;

  /* a line that outgrows its initial capacity many times over */
  typein(0,0,"0123456789");
  for(i=0;i<40;i++)typein(0,b.llen(0),"0123456789");
  if(b.llen(0)!=410)return 20;
  if(b.line(0)[409]!='9')return 21;

  /* enough lines to outgrow the initial slot count */
  for(i=0;i<200;i++)b.insline(b.n);
  if(b.n!=201)return 22;

  /* save and reload: the text must survive exactly */
  b.done();
  b.init();
  typein(0,0,"alpha");
  b.insline(1);
  typein(1,0,"beta");
  b.insline(2);          /* an empty line in the middle must survive */
  b.insline(3);
  typein(3,0,"gamma");
  if(b.dirty!=1)return 23;
  if(!b.save(path))return 24;
  if(b.dirty!=0)return 25;

  b.done();
  b.init();
  typein(0,0,"scratch");
  if(!b.load(path))return 26;
  if(b.dirty!=0)return 27;
  if(b.n!=4)return 28;
  if(!lineis(0,"alpha"))return 29;
  if(!lineis(1,"beta"))return 30;
  if(!lineis(2,""))return 31;
  if(!lineis(3,"gamma"))return 32;

  /* loading a missing file fails and leaves the buffer usable */
  if(b.load("/nonexistent/uplnc/buftest"))return 33;
  if(!lineis(0,"alpha"))return 34;

  /* A file that opens but fails while reading (a directory on Linux) must be
     transactional too: preserve both the text and its prior dirty state. */
  b.insch(0,5,'!');
  if(b.dirty!=1)return 35;
  if(b.load("/"))return 36;
  if(!lineis(0,"alpha!"))return 37;
  if((b.n!=4)||(b.dirty!=1))return 38;
  /* a load starts a fresh history: there is nothing to undo after it */
  if(!b.load(path))return 43;
  if(b.undo()||b.redo())return 44;

  /* Undo and redo, one group per editor command. The first group opens
     without a mark, so it records its first change's own position. */
  b.done();
  b.init();
  typein(0,0,"hello");
  b.mark(0,5);                   /* Enter at the end, then a new line */
  b.split(0,5);
  typein(1,0,"world");
  b.mark(1,5);                   /* two Backspaces */
  b.delch(1,4);
  b.delch(1,3);
  b.mark(1,0);                   /* Backspace at column 0 joins */
  b.join(0);
  b.mark(0,0);                   /* a line above, then both lines deleted:
                                    the last one is emptied in place */
  b.insline(0);
  typein(0,0,"top");
  b.delline(1);
  b.delline(0);
  if(!textis("")||(b.n!=1)||!b.dirty)return 45;
  if(!step(0,"hellowor",0,0))return 46;
  if(!step(0,"hello\nwor",1,0))return 47;
  if(!step(0,"hello\nworld",1,5))return 48;
  if(!step(0,"hello",0,5))return 49;
  if(!step(0,"",0,0))return 50;
  if(b.undo())return 51;
  if(b.dirty)return 52;          /* back to the state it started from */
  /* redo replays forwards, leaving the cursor after each group's last change */
  if(!step(1,"hello",0,5))return 53;
  if(!step(1,"hello\nworld",1,5))return 54;
  if(!step(1,"hello\nwor",1,3))return 55;
  if(!step(1,"hellowor",0,5))return 56;
  if(!step(1,"",0,0))return 57;
  if(b.redo())return 58;
  if(!b.dirty)return 59;
  /* a new change after undo discards what could have been redone */
  if(!step(0,"hellowor",0,0))return 60;
  if(!step(0,"hello\nwor",1,0))return 61;
  b.mark(1,3);
  b.insch(1,3,'!');
  if(b.redo())return 62;
  if(!step(0,"hello\nwor",1,3))return 63;
  if(!step(1,"hello\nwor!",1,4))return 64;

  /* the saved state: undoing back to it makes the buffer clean again */
  if(!b.save(path))return 65;
  b.mark(1,4);
  b.insch(1,4,'?');
  if(!b.dirty)return 66;
  if(!step(0,"hello\nwor!",1,4)||b.dirty)return 67;
  if(!step(1,"hello\nwor!?",1,5)||!b.dirty)return 68;
  if(!step(0,"hello\nwor!",1,4)||b.dirty)return 69;
  /* ... and is lost once a change replaces the history that reached it,
     even when the log is back to the same length */
  if(!step(0,"hello\nwor",1,3)||!b.dirty)return 70;
  b.mark(1,3);
  b.insch(1,3,'#');
  if(!step(0,"hello\nwor",1,3)||!b.dirty)return 71;
  if(!step(1,"hello\nwor#",1,4)||!b.dirty)return 72;

  /* a group ending in a split or a new line: redo leaves the cursor at the
     start of the line it made */
  b.mark(1,4);
  b.split(1,2);
  if(!step(0,"hello\nwor#",1,4))return 73;
  if(!step(1,"hello\nwo\nr#",2,0))return 74;
  b.mark(0,0);
  b.insline(3);
  if(!step(0,"hello\nwo\nr#",0,0))return 75;
  if(!step(1,"hello\nwo\nr#\n",3,0))return 76;

  b.done();
  return 42;
}
