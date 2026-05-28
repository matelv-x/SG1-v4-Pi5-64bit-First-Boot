
# Hardware Mode enums
HARDWARE_MODE_NONE = 0
HARDWARE_MODE_ORIGINAL = 1
HARDWARE_MODE_MAINBOARD_1V1 = 2
HARDWARE_MODE_PI5_PCA9685_SERVO = 3
HARDWARE_MODE_PI5_PCA9685_SERVO_TMC2209 = 4

class Electronics: # pylint: disable=too-few-public-methods

    def __new__(cls, app):
        # Detect Hardware
        hw_mode = HardwareDetector(app).get_hardware_mode()

        # initialize the correct subclass
        if hw_mode > 0:
            if hw_mode == HARDWARE_MODE_ORIGINAL:
                from electronics_original import ElectronicsOriginal # pylint: disable=import-outside-toplevel
                return ElectronicsOriginal(app)
            if hw_mode == HARDWARE_MODE_MAINBOARD_1V1:
                from electronics_mainboard_1v1 import ElectronicsMainBoard1V1 # pylint: disable=import-outside-toplevel
                return ElectronicsMainBoard1V1(app)
            if hw_mode == HARDWARE_MODE_PI5_PCA9685_SERVO:
                from electronics_pca9685_servo import ElectronicsPCA9685Servo # pylint: disable=import-outside-toplevel
                return ElectronicsPCA9685Servo(app)
            if hw_mode == HARDWARE_MODE_PI5_PCA9685_SERVO_TMC2209:
                from electronics_pca9685_servo_tmc2209 import ElectronicsPCA9685ServoTMC2209 # pylint: disable=import-outside-toplevel
                return ElectronicsPCA9685ServoTMC2209(app)

        # Default: No Electronics, simulate everything
        from electronics_none import ElectronicsNone # pylint: disable=import-outside-toplevel
        return ElectronicsNone()


class HardwareDetector:

    def __init__(self, app):
        self.log = app.log
        self.cfg = app.cfg
        self.hardware_mode = None
        self.hardware_mode_name = None

        # TODO: Refactor this to loop over the signatures in an array
        self.signature_adafruit_shields = ['0x60', '0x61', '0x62'] # HARDWARE_MODE_ORIGINAL
        self.signature_mainboard_1v1 = ['0x66', '0x6f'] # HARDWARE_MODE_MAINBOARD_1V1
        # Pi 5 custom hardware: PCA9685 servo board at 0x40 + MotorKit HAT at 0x60.
        # 0x70 is the PCA9685 all-call address and may also appear in i2cdetect.
        self.signature_pi5_pca9685_servo = ['0x40', '0x60'] # HARDWARE_MODE_PI5_PCA9685_SERVO
        self.signature_pi5_pca9685_servo_tmc2209 = ['0x40'] # HARDWARE_MODE_PI5_PCA9685_SERVO_TMC2209

        self.smbus = False
        self.import_smbus()

    def import_smbus(self):
        try:
            import smbus2 as smbus  # pylint: disable=import-outside-toplevel
            self.smbus = smbus
            return
        except ModuleNotFoundError:
            self.smbus = False
            self.log.log("Failed to import smbus2 as smbus. Assuming no I2C devices.")
            return

    def get_i2c_devices(self):
        devices = []
        # If we don't have smbus, we have no i2c devices, return an empty array
        if not self.smbus:
            return devices

        bus = self.smbus.SMBus(1) # 1 indicates /dev/i2c-1
        for device in range(128):
            try:
                bus.read_byte(device)
                devices.append(hex(device))
            except: # exception if read_byte fails # pylint: disable=bare-except
                pass
        return devices

    def get_hardware_mode(self):
        if self.hardware_mode is None:
            devices = self.get_i2c_devices()
            try:
                stepper_driver = self.cfg.get("stepper_driver")
            except Exception:  # pylint: disable=broad-except
                stepper_driver = "motorkit"

            if all( item in devices for item in self.signature_adafruit_shields ):
                self.hardware_mode = HARDWARE_MODE_ORIGINAL
            elif all( item in devices for item in self.signature_mainboard_1v1 ):
                self.hardware_mode = HARDWARE_MODE_MAINBOARD_1V1
            elif (
                stepper_driver == "tmc2209"
                and all(item in devices for item in self.signature_pi5_pca9685_servo_tmc2209)
            ):
                self.hardware_mode = HARDWARE_MODE_PI5_PCA9685_SERVO_TMC2209
            elif all( item in devices for item in self.signature_pi5_pca9685_servo ):
                self.hardware_mode = HARDWARE_MODE_PI5_PCA9685_SERVO
            else:
                self.hardware_mode = HARDWARE_MODE_NONE

        return self.hardware_mode

    def get_hardware_mode_name(self):
        return self.hardware_mode_name
