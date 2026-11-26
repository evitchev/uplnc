/* compound assignment on long long targets (64-bit everywhere; a register
   pair on i386): every operator, an int right side widened, an int target
   narrowed, through a pointer, and the value of the expression. -> 42 */
func main()
{
  var long long:a;var long long:b;var unsigned long long:u;var [2]long long:la;
  var *long long:p;var int:i;var int:ok;
  ok=0;
  a=10000000000;
  a+=5;if(a==10000000005)++ok;
  a-=10000000000;if(a==5)++ok;
  a=4000000000;a*=3;if(a==12000000000)++ok;
  a/=7;if(a==1714285714)++ok;
  a=12000000007;a%=1000;if(a==7)++ok;
  a=1;a<<=40;if(a==1099511627776)++ok;
  a>>=38;if(a==4)++ok;
  a=0-8;a>>=1;if(a==0-4)++ok;               /* arithmetic */
  u=0-1;u>>=60;if(u==15)++ok;               /* logical */
  a=1034834473200;a&=1095233372415;if(a==1030807879920)++ok;  /* F0F0F0F0F0 & FF00FF00FF */
  a|=15;if(a==1030807879935)++ok;
  a^=1030792151040;if(a==15728895)++ok;     /* ^ F000000000 */
  i=3;a=1;a+=i;if(a==4)++ok;                /* an int right side, widened */
  a=10000000000;i=0;i+=a;b=i;               /* an int target: the low bits */
  if((b==1410065408)||(b==10000000000))++ok;  /* i386 keeps the low 32 bits */
  la[0]=1;la[1]=2;p=la;p+=1;*p+=10000000000;
  if((la[1]==10000000002)&&(la[0]==1))++ok;
  b=(a+=1);if((a==10000000001)&&(b==a))++ok;
  if(ok==16)return 42;
  return ok;
}
