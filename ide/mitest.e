/* mitest.e: the MI parser's proof, on every backend and without gdb. Real
   records (gdb 10.2 driving a langc -g program; only the absolute paths are
   shortened) parsed and walked by path; every escape; the unnamed tuples of
   gdb before 13; then lines that are not records -- truncated, misnested,
   too deep, with trailing bytes, gdb's stderr -- which must come back as
   MR_OTHER with their text, and a long line and many parse/free cycles.
   On failure it prints the number of the first failing check and exits 1;
   success is exit 42.

   Build: perl src/langdrv.pl -march=ARCH -o mitest ide/mitest.e ide/mi.e */

#include "mi.he"

func exit(c:int);
func malloc(n:int);
func free(p:int);

var mtn:int;             /* checks so far */
var mtr:*mirec;          /* the record under test */

func ck(ok:int)
{
  mtn++;
  if(!ok)
  {
    printf("mitest: check %d failed\n",mtn);
    exit(1);
  }
  return 0;
}

func mteq(a:*char,b:*char)
{
  var i:int;
  if(!a)return 0;
  i=0;
  while(a[i]&&(a[i]==b[i]))i++;
  return a[i]==b[i];
}

/* parse line into mtr, freeing the previous record */
func p(line:*char)
{
  if(mtr)mtr->done();
  mtr=miparse(line);
  ck(mtr!=0);
  return mtr->type;
}

/* a heap copy of s with a CR LF line end (string literals have no \r) */
func crlf(s:*char):*char
{
  var c:*char;
  var n,i:int;
  n=0;
  while(s[n])n++;
  c=malloc(n+3);
  for(i=0;i<n;i++)c[i]=s[i];
  c[n]=13;
  c[n+1]=10;
  c[n+2]=0;
  return c;
}

/* the string at path is want */
func is(path:*char,want:*char)
{
  return ck(mteq(mtr->str(path),want));
}

/* mtr is a non-record holding exactly line */
func other(line:*char)
{
  p(line);
  ck(mtr->type==MR_OTHER);
  ck(mtr->token==0-1);
  ck(mteq(mtr->text,line));
  ck(mtr->res->count()==0);
  return 0;
}

func main()
{
  var v,w:*mival;
  var big,pre:*char;
  var i,n:int;
  var []int:esc = {'a',10,'b',9,'c',13,'d',7,'e',8,'f',12,'g',11,'h',27,'i','\\','j','"','k','q','z',0};
  /* the records of one session, in order */
  ck(p("=thread-group-added,id=\"i1\"")==MR_NOTIFY);
  ck(mteq(mtr->cls,"thread-group-added"));
  ck(mtr->token==0-1);
  is("id","i1");
  ck(p("~\"Reading symbols from ./dbg...\\n\"\n")==MR_CONSOLE);
  ck(mteq(mtr->text,"Reading symbols from ./dbg...\n"));
  ck(p("(gdb) \n")==MR_PROMPT);
  ck(p("(gdb)")==MR_PROMPT);
  ck(p("1^done,bkpt={number=\"1\",type=\"breakpoint\",disp=\"keep\",enabled=\"y\",addr=\"0x0000000000401154\",func=\"add\",file=\"dbg.e\",fullname=\"/src/dbg.e\",line=\"4\",thread-groups=[\"i1\"],times=\"0\",original-location=\"dbg.e:4\"}")==MR_RESULT);
  ck(mtr->token==1);
  ck(mteq(mtr->cls,"done"));
  is("bkpt.number","1");
  is("bkpt.func","add");
  is("bkpt.line","4");
  is("bkpt.original-location","dbg.e:4");
  is("bkpt.thread-groups.0","i1");
  ck(mtr->get("bkpt")->count()==12);
  ck(mtr->get("bkpt.thread-groups")->kind==MV_LIST);
  ck(mtr->get("bkpt.thread-groups.0")->name==0);
  big=crlf("2^running");
  ck(p(big)==MR_RESULT);
  free(big);
  ck(mtr->token==2);
  ck(mteq(mtr->cls,"running"));
  ck(mtr->res->count()==0);
  ck(p("*running,thread-id=\"all\"")==MR_EXEC);
  is("thread-id","all");
  ck(p("=library-loaded,id=\"/lib64/ld-linux-x86-64.so.2\",target-name=\"/lib64/ld-linux-x86-64.so.2\",host-name=\"/lib64/ld-linux-x86-64.so.2\",symbols-loaded=\"0\",thread-group=\"i1\",ranges=[{from=\"0x00007ffff7fd0100\",to=\"0x00007ffff7ff2684\"}]")==MR_NOTIFY);
  is("ranges.0.to","0x00007ffff7ff2684");
  ck(mtr->get("ranges.0")->kind==MV_TUPLE);
  ck(p("~\"4\\t  c=a+b;\\n\"")==MR_CONSOLE);
  ck(mteq(mtr->text,"4\t  c=a+b;\n"));
  ck(p("*stopped,reason=\"breakpoint-hit\",disp=\"keep\",bkptno=\"1\",frame={addr=\"0x0000000000401154\",func=\"add\",args=[{name=\"a\",value=\"40\"},{name=\"b\",value=\"2\"}],file=\"dbg.e\",fullname=\"/src/dbg.e\",line=\"4\",arch=\"i386:x86-64\"},thread-id=\"1\",stopped-threads=\"all\",core=\"10\"")==MR_EXEC);
  ck(mteq(mtr->cls,"stopped"));
  is("reason","breakpoint-hit");
  is("frame.func","add");
  is("frame.line","4");
  is("frame.args.1.name","b");
  is("frame.args.1.value","2");
  ck(mtr->get("frame.args")->count()==2);
  ck(mtr->get("frame.args.2")==0);
  is("core","10");
  ck(p("3^done,stack=[frame={level=\"0\",addr=\"0x0000000000401154\",func=\"add\",file=\"dbg.e\",fullname=\"/src/dbg.e\",line=\"4\",arch=\"i386:x86-64\"},frame={level=\"1\",addr=\"0x00000000004011cf\",func=\"main\",file=\"dbg.e\",fullname=\"/src/dbg.e\",line=\"11\",arch=\"i386:x86-64\"}]")==MR_RESULT);
  is("stack.0.func","add");
  is("stack.1.func","main");
  is("stack.1.line","11");
  is("stack.frame.level","0");     /* a list of results finds the first by name */
  ck(mteq(mtr->get("stack.1")->name,"frame"));
  ck(p("4^done,variables=[{name=\"a\",arg=\"1\",type=\"int\",value=\"40\"},{name=\"b\",arg=\"1\",type=\"int\",value=\"2\"},{name=\"c\",type=\"int\",value=\"140737353772000\"}]")==MR_RESULT);
  ck(mtr->get("variables")->count()==3);
  is("variables.2.value","140737353772000");
  ck(mtr->str("variables.2.arg")==0);
  ck(p("*stopped,reason=\"exited\",exit-code=\"052\"")==MR_EXEC);
  is("exit-code","052");
  ck(p("8^error,msg=\"Function \\\"nosuchfn\\\" not defined.\"")==MR_RESULT);
  ck(mteq(mtr->cls,"error"));
  is("msg","Function \"nosuchfn\" not defined.");
  ck(p("9^exit")==MR_RESULT);
  ck(mteq(mtr->cls,"exit"));
  /* the other two record kinds */
  ck(p("@\"target says hi\"")==MR_TARGET);
  ck(mteq(mtr->text,"target says hi"));
  ck(p("&\"warning: Error disabling address space randomization\\n\"")==MR_LOG);
  ck(p("+download,{section=\".text\",section-size=\"1024\"}")==MR_STATUS);
  ck(mtr->res->count()==1);
  is("0.section",".text");
  /* every escape */
  ck(p("~\"a\\nb\\tc\\rd\\ae\\bf\\fg\\vh\\ei\\\\j\\\"k\\qz\"")==MR_CONSOLE);
  for(i=0;i<24;i++)ck(mtr->text[i]==esc[i]);
  ck(p("~\"\\033[1m\\101\\0612\\7\\08\"")==MR_CONSOLE);
  ck(mtr->text[0]==27);
  ck(mtr->text[1]=='[');
  ck(mtr->text[4]=='A');           /* \101 */
  ck(mtr->text[5]=='1');           /* \061, then a plain 2 */
  ck(mtr->text[6]=='2');
  ck(mtr->text[7]==7);
  ck(mtr->text[8]==0);             /* \0 then 8: the decoded string ends */
  ck(p("~\"\\377\"")==MR_CONSOLE);
  ck(mtr->text[0]==0-1);           /* byte 255, a signed char */
  ck(p("~\"\"")==MR_CONSOLE);
  ck(mtr->text[0]==0);
  /* tokens */
  ck(p("000^done")==MR_RESULT);
  ck(mtr->token==0);
  ck(p("123456789*stopped")==MR_EXEC);
  ck(mtr->token==123456789);
  /* empty containers, a bare list, a duplicated name */
  ck(p("^done,x={},y=[],z=[\"1\",\"2\"],x=\"again\"")==MR_RESULT);
  ck(mtr->get("x")->kind==MV_TUPLE);
  ck(mtr->get("x")->count()==0);
  ck(mtr->get("y")->count()==0);
  is("z.1","2");
  ck(mtr->res->count()==4);
  is("3","again");
  /* gdb before 13: a breakpoint's extra locations follow it unnamed */
  ck(p("^done,bkpt={number=\"1\",addr=\"<MULTIPLE>\"},{number=\"1.1\",addr=\"0x1\"},{number=\"1.2\",addr=\"0x2\"}")==MR_RESULT);
  ck(mtr->res->count()==3);
  is("bkpt.addr","<MULTIPLE>");
  is("2.number","1.2");
  ck(mtr->get("1")->name==0);
  /* paths that lead nowhere */
  p("^done,a={b=\"1\"}");
  ck(mtr->get("a.c")==0);
  ck(mtr->get("a.b.c")==0);        /* through a string */
  ck(mtr->get("a.")==0);
  ck(mtr->get(".a")==0);
  ck(mtr->get("a..b")==0);
  ck(mtr->get("")!=0);             /* the empty path is the results tuple */
  ck(mtr->get("0.b")!=0);
  ck(mtr->get("1")==0);
  ck(mtr->get("0123456789012345678901234567890123456789012345678901234567890123")==0);
  ck(mtr->str("a")==0);            /* a tuple is not a string */
  v=mtr->get("a");
  ck(v->at(0-1)==0);
  ck(mteq(v->path("b")->str,"1"));
  /* lines that are not records */
  other("");
  other("warning: Error disabling address space randomization: Operation not permitted");
  other("~\"unterminated");
  other("~\"ends in a backslash\\");
  other("~\"x\" trailing");
  other("~x");
  other("12~\"a stream takes no token\"");
  other("1234567890^done");        /* ten digits */
  other("^");
  other("^,a=\"1\"");
  other("^done,");
  other("^done,a=");
  other("^done,a=\"1\",");
  other("^done,a");
  other("^done,a=1");
  other("^done,=\"1\"");
  other("^done,a:\"1\"");
  other("^done,a={b=\"1\"]");
  other("^done,a=[\"1\"}");
  other("^done,a={b=\"1\"");
  other("^done,a=\"1\"junk");
  other("^done junk");
  other("^done,a=\"1\" ");
  other("^this-class-name-is-far-too-long-to-keep");
  other("(gdb) x");
  other("(gd)");
  other("%unknown");
  /* nesting: 32 levels parse, 33 do not */
  pre="^done,a=";
  n=0;
  while(pre[n])n++;
  big=malloc(200);
  for(i=0;i<n;i++)big[i]=pre[i];
  for(i=0;i<32;i++)big[n+i]='[';
  for(i=0;i<32;i++)big[n+32+i]=']';
  big[n+64]=0;
  ck(p(big)==MR_RESULT);
  w=mtr->get("a");
  for(i=0;i<31;i++)
  {
    ck(w->count()==1);
    w=w->at(0);
  }
  ck(w->count()==0);
  for(i=0;i<33;i++)big[n+i]='[';
  for(i=0;i<33;i++)big[n+33+i]=']';
  big[n+66]=0;
  other(big);
  free(big);
  /* a long console line, and many cycles (a leak shows under valgrind) */
  big=malloc(100010);
  big[0]='~';
  big[1]='"';
  for(i=0;i<100000;i++)big[2+i]='a'+i%26;
  big[100002]='"';
  big[100003]=0;
  ck(p(big)==MR_CONSOLE);
  i=0;
  while(mtr->text[i])i++;
  ck(i==100000);
  ck(mtr->text[99999]=='a'+99999%26);
  free(big);
  for(i=0;i<2000;i++)
  {
    p("*stopped,reason=\"end-stepping-range\",frame={func=\"add\",args=[{name=\"a\",value=\"40\"}],line=\"5\"},thread-id=\"1\"");
    p("garbage {[\"");
  }
  mtr->done();
  return 42;
}
