# ESP32 Connection Guide

This guide provides step-by-step instructions for connecting your ESP32 to BP Mobile.

## Step 1: Get Connection Information

1. Open BP Mobile app
2. Navigate to **Hamburger Menu → Network Management**
3. Note the following information:
   - **IP Address**: The IP address your ESP32 should connect to
   - **Port**: Default is 3000 (can be changed in Network Management)
   - **WebSocket URL**: Full connection URL (e.g., `ws://192.168.43.1:3000`)

## Step 2: Enable External Publisher

1. Navigate to **Publishers** view in BP Mobile
2. Enable the **External (ESP32)** publisher toggle
3. Wait for the WebSocket server to start (status will show "Active")
4. The WebSocket URL will be displayed in the connection info card

## Step 3: Configure Your ESP32

### WiFi Connection

```cpp
// For Hotspot mode
const char* ssid = "YourPhoneHotspotSSID";
const char* password = "YourHotspotPassword";

// For Shared WiFi
const char* ssid = "YourWiFiNetwork";
const char* password = "YourWiFiPassword";
```

### WebSocket Server

```cpp
const char* serverHost = "192.168.43.1";  // From BP Mobile Network Management
const int serverPort = 3000;              // From BP Mobile Network Management
```

## Step 4: Establish Connection

1. Connect ESP32 to WiFi (hotspot or shared network)
2. Create WebSocket connection to the server
3. Register with a unique client name
4. Start sending data

## Step 5: Verify Connection

1. In BP Mobile, go to **Hamburger Menu → Client Management**
2. Your ESP32 should appear in the "Connected ESP32 Clients" list
3. Check connection status:
   - **Active**: Connected and healthy
   - **Disconnected**: Connection lost
4. View connection quality indicators:
   - **Excellent**: less than 50ms latency, 0 missed pings
   - **Good**: less than 100ms latency, less than 2 missed pings
   - **Fair**: less than 200ms latency, less than 3 missed pings
   - **Poor**: Higher latency or more missed pings

## Troubleshooting

### ESP32 Cannot Connect

- Verify WiFi credentials are correct
- Check that phone hotspot is enabled (if using hotspot mode)
- Ensure ESP32 and phone are on the same network
- Verify IP address and port from Network Management

### Connection Drops Frequently

- Check WiFi signal strength
- Ensure power supply is stable
- Review connection quality indicators in Client Management
- Check for interference from other devices

### Client Name Already Exists

- Each ESP32 must have a unique client name
- If you see this error, choose a different name
- Recommended format: `ESP32_DeviceType_Number` (e.g., `ESP32_Sensor_01`)

### Topics Not Appearing

- Ensure topics are properly registered during client registration
- Check that topics are subscribed in Client Management
- Verify topic format: `client_name/topic_tree`

## Next Steps

- Review the [WebSocket Protocol](/docs/protocol) for message formats
- See [Code Examples](/docs/examples) for implementation details
