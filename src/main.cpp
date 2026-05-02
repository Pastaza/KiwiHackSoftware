#include <BleMouse.h>
#include <Arduino.h>

BleMouse bleMouse;

// Confirmed working pins
const int ledPins[] = {1, 2, 3, 4};
const int ledCount = 4;

const bool LED_ACTIVE_LOW = false;

// Mouse movement
int8_t dx = 6;
int8_t dy = 6;
int stepCount = 0;
int stepsPerDirection = 40;

unsigned long lastMouseMoveTime = 0;
const unsigned long mouseMoveInterval = 100;

// LED flashing
bool flashingAllLeds = false;
bool flashState = false;
unsigned long lastFlashTime = 0;
const unsigned long flashInterval = 250;

// Serial command buffer
String serialMessage = "";

void setLed(int index, bool on) {
  if (LED_ACTIVE_LOW) {
    digitalWrite(ledPins[index], on ? LOW : HIGH);
  } else {
    digitalWrite(ledPins[index], on ? HIGH : LOW);
  }
}

void setAllLeds(bool on) {
  for (int i = 0; i < ledCount; i++) {
    setLed(i, on);
  }
}

void showProgress(int imageIndex) {
  /*
    P0 -> 1 LED
    P1 -> 2 LEDs
    P2 -> 3 LEDs
    P3 -> all 4 LEDs flashing
  */

  if (imageIndex == 3) {
    flashingAllLeds = true;
    flashState = true;
    lastFlashTime = millis();
    setAllLeds(true);
    return;
  }

  flashingAllLeds = false;

  for (int i = 0; i < ledCount; i++) {
    setLed(i, i <= imageIndex);
  }
}

void updateLedFlashing() {
  if (!flashingAllLeds) {
    return;
  }

  unsigned long now = millis();

  if (now - lastFlashTime >= flashInterval) {
    lastFlashTime = now;
    flashState = !flashState;
    setAllLeds(flashState);
  }
}

void handleSerialCommand(String msg) {
  msg.trim();

  if (msg == "P0") {
    showProgress(0);
  } else if (msg == "P1") {
    showProgress(1);
  } else if (msg == "P2") {
    showProgress(2);
  } else if (msg == "P3") {
    showProgress(3);
  } else if (msg == "RESET" || msg == "R") {
    flashingAllLeds = false;
    showProgress(0);
  }
}

void readSerialCommands() {
  while (Serial.available() > 0) {
    char c = Serial.read();

    if (c == '\n') {
      handleSerialCommand(serialMessage);
      serialMessage = "";
    } else if (c != '\r') {
      serialMessage += c;
    }
  }
}

void updateMouseMovement() {
  if (!bleMouse.isConnected()) {
    return;
  }

  unsigned long now = millis();

  if (now - lastMouseMoveTime < mouseMoveInterval) {
    return;
  }

  lastMouseMoveTime = now;

  bleMouse.move(dx, dy);

  stepCount++;

  if (stepCount >= stepsPerDirection) {
    stepCount = 0;

    dx = (random(2) == 0 ? 1 : -1) * random(1, 5);
    dy = (random(2) == 0 ? 1 : -1) * random(1, 5);
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);

  for (int i = 0; i < ledCount; i++) {
    pinMode(ledPins[i], OUTPUT);
  }

  // Start on image 1: one LED lit.
  showProgress(0);

  bleMouse.begin();
}

void loop() {
  readSerialCommands();

  updateLedFlashing();

  updateMouseMovement();
}