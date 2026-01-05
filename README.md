# Spirit FlowSync
A script to synchronize local 'SpiritIT Flow-X' and a remote API. It's made to work with [Flow DASH](https://github.com/DR-Lars/Flow-DASH), but you can set up your own API if you desire.

### FlowSync-Test.ps1
A script to quickly test the local and remote api.

## Environment variables
You require some environment variables for the app to work these are:
- METER_ID: The ID you want to identify the meter with on this ship (ex.: METER_ID=1)
- SHIP_NAME: The name of the ship this meter is located on (ex.: SHIP_NAME=Titanic)
- ARCHIVE_NAME: The name of the archive where the snapshots are stored (ex.:ARCHIVE_NAME=BatchLogging1)
- LOCAL_API_URL: The URL of the local flowmeter API, changing only the IP should be enough (ex.: LOCAL_API_URL=http://192.168.0.10)
- REMOTE_API_URL: The URL of the API the data can be checked at with parameters meter_id, ship_name, and batch_number (ex.: REMOTE_API_URL=https://flow.dash.com/api/report)
- REMOTE_API_URL_BATCH: The URL of the API the data should be posted to (ex.: REMOTE_API_URL=https://flow.dash.com/api/report/BATCH)
(examples are for Flow DASH) 
- REMOTE_API_TOKEN: Bearer token to authorise API access (ex.: REMOTE_API_TOKEN=Access123!)

## Scheduled task
I recommend setting up a scheduled task on a local Windows computer that is almost always on.
1. Open Task Scheduler → Create Task:
2. Triggers: “Daily” + “Repeat task every: 1 hour”
3. Actions: powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\Sync-LocalToRemote.ps1"
4. Run whether user is logged on or not; set appropriate user.

## JSON post format
```json
{
    "ship_name": "Titanic",
    "meter_id": "1",
    "batch_number": "42",
    "snapshots": [
        {
            "uuid": "5697A460217BC1F0A6620C670E1B4D9B587470E2",
            "timestamp": "2025-11-22 08:22:22",
            "name": "",
            "id": 76030,
            "version": "1.0.0",
            "archive": "BatchLogging1",
            "snapshot": {
                "PN": "85-111-5",
                "SN": "24-5-1-88",
                "rnd": "D893D61E9AA1435",
                "tags": {
                    "BB_BATCHING!RUN1_PRODUCT_NAME": {
                        "v": "Gasoil"
                    },
                    "BB_Batching!RUN1_BATCH_APPROVED_MASS_CUR": {
                        "v": 1
                    },
                    "BB_Batching!RUN1_BATCH_APPROVED_VOL_CUR": {
                        "v": 1
                    },
                    "BB_Batching!RUN1_BATCH_NONACC_RATIO_MASS_CUR": {
                        "u": "perc",
                        "v": 0
                    },
                    "BB_Batching!RUN1_BATCH_NONACC_RATIO_VOL_CUR": {
                        "u": "perc",
                        "v": 0
                    },
                    "BB_MiMO!RUN1_LEFT_VOLT": {
                        "u": "mV",
                        "v": 0.134616762399674
                    },
                    "BB_MiMO!RUN1_LIVE_ZERO": {
                        "u": "tonne_hr",
                        "v": -6.87722730636597
                    },
                    "BB_MiMO!RUN1_MASS_TOTAL": {
                        "u": "tonne",
                        "v": 0
                    },
                    "BB_MiMO!RUN1_RIGHT_VOLT": {
                        "u": "mV",
                        "v": 0.136139690876007
                    },
                    "BB_MiMO!RUN1_TUBE_FREQ": {
                        "u": "Hz",
                        "v": 78.9859237670898
                    },
                    "BB_MiMo!RUN1_AERATION_CUR": {
                        "u": "perc",
                        "v": 31.1529750823975
                    },
                    "BB_MiMo!RUN1_DRIVE_GAIN": {
                        "u": "perc",
                        "v": 99.9999008178711
                    },
                    "BB_MiMo!RUN1_LIQUID_DETECTOR": {
                        "v": true
                    },
                    "LM_RUN1!RUN1_BATCH_NR_PRV": {
                        "v": 225
                    },
                    "LM_RUN1!RUN1_GSV_ACC_BTOT_FWD_CUR": {
                        "u": "sm3",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_GSV_NACC_BTOT_FWD_CUR": {
                        "u": "sm3",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_GV_ACC_BTOT_FWD_CUR": {
                        "u": "m3",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_GV_NACC_BTOT_FWD_CUR": {
                        "u": "m3",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_MASS_ACC_BTOT_FWD_CUR": {
                        "u": "tonne",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_MASS_NACC_BTOT_FWD_CUR": {
                        "u": "tonne",
                        "v": 0
                    },
                    "LM_RUN1!RUN1_MTR_MANUF": {
                        "v": "Emerson"
                    },
                    "LM_RUN1!RUN1_MTR_MODEL": {
                        "v": "HC2"
                    },
                    "LM_RUN1!RUN1_MTR_SERIALNR": {
                        "v": 13695677
                    },
                    "LM_RUN1!RUN1_MTR_SIZE": {
                        "v": "6\""
                    },
                    "LM_Run1!RUN1_CPL_CUR": {
                        "u": "none",
                        "v": 1.00000104886751
                    },
                    "LM_Run1!RUN1_CTL_CUR": {
                        "u": "none",
                        "v": 0.988797801710622
                    },
                    "LM_Run1!RUN1_CTPL_CUR": {
                        "u": "none",
                        "v": 0.988798838828512
                    },
                    "LM_Run1!RUN1_DT_CUR": {
                        "u": "kg_m3",
                        "v": 639.157958984375
                    },
                    "LM_Run1!RUN1_GSVR_CUR": {
                        "u": "sm3_hr",
                        "v": 0
                    },
                    "LM_Run1!RUN1_GSV_BTOT_FWD_CUR": {
                        "u": "sm3",
                        "v": 0
                    },
                    "LM_Run1!RUN1_GSV_FWD_CUM": {
                        "u": "sm3",
                        "v": 348090.426
                    },
                    "LM_Run1!RUN1_GVR_CUR": {
                        "u": "m3_hr",
                        "v": 0
                    },
                    "LM_Run1!RUN1_GV_BTOT_FWD_CUR": {
                        "u": "m3",
                        "v": 0
                    },
                    "LM_Run1!RUN1_GV_FWD_CUM": {
                        "u": "m3",
                        "v": 349509.8
                    },
                    "LM_Run1!RUN1_MASSR_CUR": {
                        "u": "tonne_hr",
                        "v": 0
                    },
                    "LM_Run1!RUN1_MASS_BTOT_FWD_CUR": {
                        "u": "tonne",
                        "v": 0
                    },
                    "LM_Run1!RUN1_MASS_FWD_CUM": {
                        "u": "tonne",
                        "v": 282772.404
                    },
                    "LM_Run1!RUN1_MF_CUR": {
                        "u": "none",
                        "v": 1
                    },
                    "LM_Run1!RUN1_MKF_CUR": {
                        "u": "pls_unit",
                        "v": 1000
                    },
                    "LM_Run1!RUN1_PT_CUR_GAUGE": {
                        "u": "bar_g",
                        "v": 0.00524274706754069
                    },
                    "LM_Run1!RUN1_SD_CUR": {
                        "u": "kg_sm3",
                        "v": 646.398371323484
                    },
                    "LM_Run1!RUN1_TT_CUR": {
                        "u": "degC",
                        "v": 22.4025529603157
                    },
                    "SYS!SYS_COMPANY": {
                        "v": "MTS Beethoven"
                    },
                    "SYS!SYS_DESCRIPTION": {
                        "v": "Barge"
                    },
                    "SYS!SYS_LOCATION": {
                        "v": "ARA Region"
                    },
                    "SYS!SYS_TAG": {
                        "v": "FC-001"
                    },
                    "SYS!TIME_CUR": {
                        "v": "08:22:21"
                    },
                    "mod1_IO!PIN1_A_CUM": {
                        "v": 1651545081
                    },
                    "mod1_IO!PIN1_B_CUM": {
                        "v": 0
                    },
                    "mod1_IO!PIN1_FRQ_A": {
                        "u": "Hz",
                        "v": 0
                    },
                    "mod1_IO!PIN1_FRQ_B": {
                        "u": "Hz",
                        "v": 0
                    },
                    "mod1_IO!PIN1_PHASEDIFF": {
                        "u": "deg",
                        "v": 0
                    }
                },
                "ts": "2025-11-22 08:22:22.019"
            }
        },
        {...},
        {...}
    ]
}
```
