/*
Web Server, Pulse Logger, NTP time client, for Carcano spa
31.10.2011
This code is GPL. see www.gnu.org for details

be careful in increasing string space. this software uses almost all the arduino ATMEGA328 memory (2Kb)

SDcard Datalogger v0.10
mgua@tomware.it
fgentili@tomware.it

Arduino-Ethernet:
TCPIP Webserver with 
NTP client
Asynchronous Interrupt (IRQ0) pulse counter on Digital pin2
DataLogger on Micro SDcard file

* Ethernet shield attached to pins 10, 11, 12, 13
* Analog inputs attached to pins A0 through A5 (optional)
* Digital input with raising front pulse counter on digital PIN2

NTP protocol is used to sync from a time server 
in arduino 022 download time.zip
http://www.arduino.cc/playground/Code/Time
http://www.arduino.cc/playground/uploads/Code/Time.zip
   and put its contents in 
     libraries/DS1307RTC
     libraries/Time
     libraries/TimeAlarms

SDcard is accessed via SPI protocol standard, which is also used to program ethernet Wiznet controller.
In order to interact with SD, we need to set pin10 as output otherwise SD library will not work

*/

#include <SPI.h>
#include <Ethernet.h>
#include <Udp.h>
#include <Time.h>
#include <SD.h>

byte mac[] = { 0xDA, 0xAD, 0xBE, 0xEE, 0xFE, 0xED };
byte ip[] = { 10, 2, 3, 51 };
byte mask[] = { 255, 255, 0, 0 };
byte gateway[] = { 10, 2, 0, 1 };
byte timeServer[] = { 10, 2, 3, 60 };
                                          // seconds to add to UTCtime to consider correct timezone
// const unsigned long UTCcorrection = 7200; // CET = UTC + 1 (+2 in summer):  (HOW to properly calculate DST?)
const unsigned long UTCcorrection = 0;    // keep UTC
const int NTP_PACKET_SIZE= 48;            // NTP time stamp is in the first 48 bytes of the message
byte packetBuffer[NTP_PACKET_SIZE];       // buffer to hold incoming and outgoing packets
unsigned int localPort = 8989;            // local port to listen for UDP packets
Server server(80);                        // local listener port for http services

// variable for pulsecounter, to be altered from inside interrupt routine (requires volatile)
volatile unsigned long pulses = 0;
int pulsePin = 2;  // use pin2 for async pulse counter IRQ0 is connected to PIN2, (IRQ1 is connected to pin 3)

const unsigned long seventyYears = 2208988800UL;     
unsigned long epoch = seventyYears;

const int EthChipSelect = 10;
const int SDChipSelect = 4;
time_t logInterval = 10UL;          // append to file every loginterval seconds
time_t lastLogTime = 0UL;         
time_t syncInterval = 60UL;         // ntp sync every syncinterval seconds
time_t lastSyncTime = 0UL;        

unsigned long logLinesWritten = 0;
const int maxLogLines = 7;
boolean fileFull = false;
char* logFileName = "log.txt";
unsigned long logFileSize = 0;  //logfilesize added from last powerup

unsigned long sendNTPpacket(byte *address) {
  memset(packetBuffer, 0, NTP_PACKET_SIZE); // set all bytes in the buffer to 0
  // Initialize values needed to form NTP request
  packetBuffer[0] = 0b11100011;   // LI, Version, Mode
  packetBuffer[1] = 0;     // Stratum, or type of clock
  packetBuffer[2] = 6;     // Polling Interval
  packetBuffer[3] = 0xEC;  // Peer Clock Precision
  // 8 bytes of zero for Root Delay & Root Dispersion
  packetBuffer[12]  = 49;
  packetBuffer[13]  = 0x4E;
  packetBuffer[14]  = 49;
  packetBuffer[15]  = 52;
  // Now send packet requesting a timestamp to server udp port NTP 123
  Udp.sendPacket( packetBuffer,NTP_PACKET_SIZE, address, 123);
}


void ntpTimeSync() {
  sendNTPpacket(timeServer); // send an NTP packet to a time server & wait if a reply is available
  delay(1000);  
  if ( Udp.available() ) {  
    Udp.readPacket(packetBuffer,NTP_PACKET_SIZE);  // read the packet into the buffer
    // the timestamp starts at byte 40 of the received packet and is four bytes,
    // or two words, long. First, esxtract the two words:
    unsigned long highWord = word(packetBuffer[40], packetBuffer[41]);
    unsigned long lowWord = word(packetBuffer[42], packetBuffer[43]);  
    // combine the four bytes (two words) into a longint: NTP time (seconds since Jan 1 1900)
    unsigned long secsSince1900 = highWord << 16 | lowWord;  
    // NTP gives secs from 1 1 1900. Unix time starts on Jan 1 1970. In seconds, that's 2208988800:
    // subtract seventy years:
    epoch = secsSince1900 - seventyYears;  
    Serial.print("T=");
  } else {
    Serial.print("Te!"); 
  }
  Serial.println(epoch);    
  time_t t = epoch + UTCcorrection;
  setTime(t);    // sets arduino internal clock
}

String getTimeString() {
  // gives back hh:mm:ss
  time_t t = now();
  String s = "";
  if (hour(t) <10) s = s + "0";
  s = s + hour(t) + ":";
  if (minute(t) <10) s = s + "0";
  s = s + minute(t) + ":";
  if (second(t) <10) s = s + "0";
  s = s + second(t);
  return(s);
}


String getDateString() {
  // gives back dd/mm/yyyy
  time_t t = now();
  String s = "";
  if (day(t) <10) s = s + "0";
  s = s + day(t) + "/";
  if (month(t) <10) s = s + "0";
  s = s + month(t) + "/";
  s = s + year(t);
  return(s);  
}


void tic() {  // IRR Interrupt response routine, bump counter when signal raising front seen
  pulses++;
}



void setup()
{
  Serial.begin(9600);
  Serial.print("R:");
  Serial.println(FreeRam());
  // setup interrupt logic
  pinMode(pulsePin, INPUT);        // non strettamente necessaria, in quanto IRQ0 e' sempre agganciata a pin2
  attachInterrupt(0, tic, RISING); // LOW-CHANGE-RISING-FALLING tic is the function pointer to the RRI
  Serial.println("I");
  Ethernet.begin(mac,ip,gateway,mask);
  Udp.begin(localPort);
  Serial.println("E");
  ntpTimeSync();
  Serial.print("SD");
  pinMode(EthChipSelect, OUTPUT);
  if (!SD.begin(SDChipSelect)) {
    Serial.println("e!");
    while(1); // fatal: wait forever
  }
  Serial.println();  
  Serial.println("H");  
  server.begin();
  Serial.println("-");  
}


void webServer() {
// sends log content if something is specified
  String creq;
  Client client = server.available();
  if (client) {
    while (client.connected()) {
      if (client.available()) {
        char c = client.read();
        if (c != '\n' && c != '\r') {
          creq += c;
          continue;
        }  
      }
      Serial.print("[");  
      Serial.print(creq); 
      Serial.println("]");
      if (creq[5] != 'x' && creq[5] != 'X') {      // http://172.30.4.47/x or http://172.30.4.47/X requests log, else std page
        client.println("HTTP/1.1 200 OK");
        client.println("Content-Type: text/html");
        client.println();
        client.print("TomWare PulseLogger 0.8");
        client.println("<p>http://ip/X ->log");
        client.println("<hr>");
        client.print("T:");
        client.print(getTimeString());
        client.println("<p>");
        client.print("D:");
        client.print(getDateString());
        client.println("<p>");
        client.print("p2 pulses:");
        client.print(pulses);
        client.print("<p>");
        client.print("log:");
        client.print(logFileName);
        client.println("<p>");
        client.print("lines:");
        client.print(logLinesWritten);
        client.println("<p>");
        client.print("logsize:");
        client.print(logFileSize);
        client.println("<p>");
        client.print("ram:");
        client.print(FreeRam());
        client.println("<p>");
      } else {                                             // LOG REQUESTED
        File dataFile = SD.open(logFileName, FILE_READ);
        if (! dataFile) {
          client.println("HTTP/1.1 404 Not Found");
          client.println("Content-Type: text/html");
          client.println();
          client.println("File Not Found!");
        }
        Serial.println("W");
        client.println("HTTP/1.1 200 OK");
        client.println("Content-Type: text/plain");
        client.println();
        char k;
        while ((k = dataFile.read()) > 0) {
          client.print((char)k);
        }
        dataFile.close();
        if (fileFull) {  // start a new file if file full, deleting contents just sent
          Serial.print("D");
          SD.remove(logFileName);
          Serial.println(".");
          fileFull = false;
        }
      }
      delay(1);     // give the web browser time to receive the data
      client.stop();
    }
  }  
}



void logToFile() {
  // always log to logFileName file
  File logFile = SD.open(logFileName, FILE_WRITE);  
  if (logFile) {
    String s = "";
    time_t t = now();
    s = String(t) + "," + String(pulses);
    for (int analogChannel = 0; analogChannel < 6; analogChannel++) {
      s += ",";
      s += String(analogRead(analogChannel));
    }
    logFile.println(s);
    logFileSize = logFile.size();
    logFile.close();
    Serial.println(s);
    logLinesWritten++;
  } else {
    Serial.println("SDe!");
    while(1); // fatal: wait forever
  }
}


void loop() {
  webServer();
  time_t t = now();
  if ((t - lastLogTime) >= logInterval) {
    lastLogTime = t;
    Serial.print("F:");
    Serial.println(FreeRam());
    Serial.print("L:");
    Serial.println(logLinesWritten);
    logToFile();
    if ((logLinesWritten % maxLogLines) == 0) {
      Serial.println("FF"); 
      fileFull = true;
    }
  }
  if ((t - lastSyncTime) > syncInterval) {
    lastSyncTime = t;
    Serial.println("N");  
    ntpTimeSync();
  } 
}
