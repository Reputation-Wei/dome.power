const assert = require('node:assert/strict')
const { parseBatteryTemperature } = require('../Model.js')

assert.equal(parseBatteryTemperature('  F75303_CPU: 40 C\n  Battery:      30 C\n  PECI: 49 C'), 30)
assert.equal(parseBatteryTemperature('Battery: 30.5 C\r\n'), 30.5)
assert.equal(parseBatteryTemperature('Battery: -5 °C'), -5)
for (const invalid of ['', 'CPU: 30 C', 'Battery: unavailable', 'Battery: 255 C', 'Battery: -273 C', 'Battery: 30 C error', null]) {
  assert.equal(parseBatteryTemperature(invalid), null)
}
console.log('Battery temperature tests passed')
