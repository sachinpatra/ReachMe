//
//  ServiceRequest.swift
//  ReachMe
//
//  Created by Sachin Kumar Patra on 2/23/18.
//  Copyright © 2018 sachin. All rights reserved.
//

import Foundation
import Alamofire
import SwiftyUserDefaults
import PhoneNumberKit
import CountryPickerView
import UserNotifications
import CoreData

open class ServiceRequest: NSObject {
    
    public static let shared = ServiceRequest()
    private let coreDataStack = Constants.appDelegate.coreDataStack
        
    var mqttSession: MQTTSession?
    
    func connectMQTT() {
        let clientID = String(format: "iv/pn/device%012ld", (Constants.appDelegate.userProfile?.mqttSettings?.mqttDeviceID)!)
        self.mqttSession = MQTTSession(host: Constants.URL_MQTT_SERVER,
                                  port: 8883,
                                  clientID: clientID,
                                  cleanSession: true,
                                  keepAlive: 60,
                                  useSSL: true)
        self.mqttSession?.delegate = self
    
        self.mqttSession?.connect {
            guard $0 else { print("Error Occurred During MQTT Connection \($1)"); return }
            
            self.mqttSession?.subscribe(to: clientID, delivering: .atLeastOnce) {
                guard $0 else { print("Error Occurred During MQTT Subscribe \($1)"); return }
                
                let payload = RMUtility.getPayloadForMQTT()
                self.mqttSession?.publish(payload, in: (Constants.appDelegate.userProfile?.mqttSettings?.chatTopic)!, delivering: .atLeastOnce, retain: false, completion: {
                    guard $0 else { print("Error Occurred During MQTT Connect Publish \($1)"); return }
                })
            }
        }
    }
    
    func disConnectMQTT() {
        let payload = RMUtility.getPayloadForMQTT()
        mqttSession?.publish(payload, in: (Constants.appDelegate.userProfile?.mqttSettings?.chatTopic)!, delivering: .atLeastOnce, retain: false, completion: {

            self.mqttSession?.disconnect()
            guard $0 else { print("Error Occurred During MQTT Disconnect Publish \($1)"); return }
        })
    }

    func parseCommonResponseforLoginProcess(responseDics: [String: Any]) {
        Defaults[.APIUserSecureKey] = responseDics[DefaultsKeys.APIUserSecureKey._key] as? String
        Defaults[.APIIVUserIDKey] = responseDics[DefaultsKeys.APIIVUserIDKey._key] as! Int

        coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
            let userProfile = RMUtility.getProfileforConext(context: context)
            userProfile?.volumeMode = .Speaker
            userProfile?.fbConnectURL = responseDics["fb_connect_url"] as? String
            userProfile?.isFBConnected = responseDics["fb_connected"] as! Bool
            userProfile?.twConnectURL = responseDics["tw_connect_url"] as? String
            userProfile?.isTWConnected = responseDics["tw_connected"] as! Bool
            // The context is saved at the end of this block, no need to call the `saveContext` method.
        })
    }
    
    func handleserviceError(response: DataResponse<Any>) -> [String: Any]? {
        guard response.result.isSuccess else {
            ANLoader.hide()
            RMUtility.showAlert(withMessage: (response.result.error?.localizedDescription)!)
            return nil
        }
        
        guard let responseDics = response.result.value as? [String: Any] else { return nil }
        guard (responseDics["status"] as! String) != "error" else {
            ANLoader.hide()
            RMUtility.showAlert(withMessage: responseDics["error_reason"] as! String, title: "Error")
            return nil
        }
        
        return responseDics
    }
    
    func handleFetchMessagesResponse(responseDics: [String: Any]) {
        Defaults[.APIFetchAfterMsgID] = responseDics["last_fetched_msg_id"]
        
        self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
            let userProfile = RMUtility.getProfileforConext(context: context)!
            
            for fetchedMessage in (responseDics["msgs"] as! [[String: Any]]) {
                
                //If message exists with same ID, skip it
                let predicate = NSPredicate(format: "messageID == %ld", fetchedMessage["msg_id"] as! Int64)
                if userProfile.messages?.filtered(using: predicate).first as? Message != nil {
                    continue
                }
                
                //New Message
                let message = NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.MESSAGE, into: context) as! Message
                message.content = fetchedMessage["msg_content"] as? String
                message.contentType = fetchedMessage["msg_content_type"] as? String
                message.flow = fetchedMessage["msg_flow"] as? String
                message.fromPhoneNumber = fetchedMessage["from_phone_num"] as? String
                message.guide = fetchedMessage["guid"] as? String
                message.misscallReason = fetchedMessage["misscall_reason"] as? String
                message.senderName = fetchedMessage["sender_id"] as? String
                message.sourceAppType = fetchedMessage["source_app_type"] as? String
                message.subtype = fetchedMessage["msg_subtype"] as? String
                message.type = fetchedMessage["type"] as? String
                message.mediaFormat = fetchedMessage["media_format"] as? String
                message.date = fetchedMessage["msg_dt"] as! Int64
                message.fromIVUserID = fetchedMessage["from_iv_user_id"] as! Int64
                message.linkedMsgID = fetchedMessage["linked_msg_id"] as! Int64
                message.messageID = fetchedMessage["msg_id"] as! Int64
                message.readCount = fetchedMessage["msg_read_cnt"] as! Int16
                message.downloadCount = fetchedMessage["msg_download_cnt"] as! Int16
                message.isBase64 = fetchedMessage["is_msg_base64"] as! Bool
                
                for messageContact in (fetchedMessage["contact_ids"] as! [[String: Any]]) {
                    if messageContact["contact_id"] as? String == message.fromPhoneNumber {
                        message.fromUserType = messageContact["type"] as? String
                    } else {
                        message.receivePhoneNumber = messageContact["contact_id"] as? String
                    }
                }
                
                userProfile.addToMessages(message)
            }
            if let error = saveBlock(true) {
                print("Coredata merge failed from writer context to default context. \(error.localizedDescription)")
            }
        })
    }
}

// MARK: - JOIN_USER API
extension ServiceRequest {
    
    func startRequestForJoinUser(completionHandler:@escaping (AutheticationType, String?) -> Void) {
        
        var params: [String: Any] = ["phone_num": (Constants.appDelegate.userProfile?.userID)!,
                                     "phone_num_edited": true,
                                     "opr_info_edited": true,
                                     "device_id": Constants.DEVICE_UUID,
                                     "sim_country_iso": (Constants.appDelegate.userProfile?.countryISOCode)!,
                                     "sim_opr_mcc_mnc": Constants.appDelegate.userProfile?.simMCCMNCNumber ?? "na", //If not available pass "na" as per API Doc
                                     "cmd": Constants.ApiCommands.JOIN_USER,
                                     "sim_serial_num": ""]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Join User", qos: .background)) { (response) in
                
                guard response.result.isSuccess else {
                    RMUtility.deleteUserProfile()
                    completionHandler(.error, (response.result.error?.localizedDescription)!)
                    return
                }
                
                guard let responseDics = response.result.value as? [String: Any] else { return }
                guard (responseDics["status"] as! String) != "error" else {
                    RMUtility.deleteUserProfile()
                    completionHandler(.error, responseDics["error_reason"] as? String)
                    return
                }
                
                Defaults[.APIIsRMNewUser] = responseDics[DefaultsKeys.APIIsRMNewUser._key] as! Bool

                switch responseDics["action"] as! String {
                case "pwd_set":
                    completionHandler(.authTypePassword, nil)
                    
                case "otp_sent":
                    Defaults[.APIRegSecureKey] = responseDics[DefaultsKeys.APIRegSecureKey._key] as? String
                    Defaults[.APIPnsAppIdKey] = responseDics[DefaultsKeys.APIPnsAppIdKey._key] as? String
                    Defaults[.APIDocURLKey] = responseDics[DefaultsKeys.APIDocURLKey._key] as? String
                    
                    completionHandler(.authTypeOTP, nil)
                    
                case "set_primary_pwd":
                    let alert = UIAlertController(style: .alert, title: "Multi Login", message: """
                                                You are already logged into your account on different device
                                                Please set password on your first device
                                                Go to Settings -> Account -> Set Password
                                                """)
                    alert.addAction(title: "OK", handler: { _ in
                        //TODO: Handle Multiple Login
                        completionHandler(.authTypeMultiuser, nil)
                    })
                    alert.show()
                    
                default:
                    break
                }
        }
    }
}

// MARK: - VERIFY_USER API
extension ServiceRequest {
    
    func startRequestForVerifyUser(otpString: String, completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = [DefaultsKey<Any>.APIRegSecureKey._key: Defaults[.APIRegSecureKey]!,
                                    "pin": otpString,
                                    "cmd": Constants.ApiCommands.VERIFY_USER,
                                    DefaultsKey<Any>.APICloudeSecureKey._key: Defaults[.APICloudeSecureKey] as Any]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Verify User", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                //Handle response Data
                ServiceRequest.shared.parseCommonResponseforLoginProcess(responseDics: responseDics)

                ServiceRequest.shared.startRequestForGetProfileInfo(completionHandler: { (success) in
                    guard success else { return }
                    ServiceRequest.shared.startRequestForFetchSettings(completionHandler: { (success) in
                        guard success else { return }

                        completionHandler(true)
                    })
                })
        }
    }
}

// MARK: - SIGNIN API
extension ServiceRequest {
    
    func startRequestForSignIn(passWord: String, completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["login_id": (Constants.appDelegate.userProfile?.userID)!,
                                    "pwd": passWord,
                                    "cmd": Constants.ApiCommands.SIGNIN,
                                    "device_id": Constants.DEVICE_UUID,
                                    "sim_country_iso": (Constants.appDelegate.userProfile?.simISOCode)!,
                                    "sim_opr_mcc_mnc": (Constants.appDelegate.userProfile?.simMCCMNCNumber)!]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "SignIn", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                //Handle response Data
                ServiceRequest.shared.parseCommonResponseforLoginProcess(responseDics: responseDics)

                Defaults[.APIPnsAppIdKey] = responseDics[DefaultsKeys.APIPnsAppIdKey._key] as? String
                Defaults[.APIDocURLKey] = responseDics[DefaultsKeys.APIDocURLKey._key] as? String

                self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
                    let userProfile = RMUtility.getProfileforConext(context: context)
                    userProfile?.userName = responseDics["screen_name"] as? String
                    userProfile?.password = passWord
                })
                            
                ServiceRequest.shared.startRequestForGetProfileInfo(completionHandler: { (success) in
                    guard success else { return }
                    ServiceRequest.shared.startRequestForFetchSettings(completionHandler: { (success) in
                        guard success else { return }
                        
                        completionHandler(true)
                    })
                })
        }
    }
}

// MARK: - GET_PROFILE_INFO API
extension ServiceRequest {
    
    func startRequestForGetProfileInfo(completionHandler:@escaping (Bool) -> Void) {
            
        var params: [String: Any] = ["cmd": Constants.ApiCommands.GET_PROFILE_INFO]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Profile Info", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
                    let userProfile = RMUtility.getProfileforConext(context: context)!
                    
                    //Handle response Data
                    userProfile.thumbnailPicURL = responseDics["thumbnail_profile_pic_uri"] as? String
                    userProfile.city = responseDics["city"] as? String
                    userProfile.emailID = responseDics["email"] as? String
                    userProfile.gender = responseDics["gender"] as? String
                    userProfile.profilePicURL = responseDics["profile_pic_path"] as? String
                    userProfile.userName = responseDics["screen_name"] as? String
                    userProfile.state = responseDics["state"] as? String
                    userProfile.twPostEnabled = responseDics["tw_post_enabled"] as! Bool
                    userProfile.fbPostEnabled = responseDics["fb_post_enabled"] as! Bool
                    userProfile.inviteSMSText = responseDics["invite_sms_text"] as? String
                    
                    if let dateOfBirth = responseDics["date_of_birth"] as? [String: Int] {
                        if let year = dateOfBirth["year"], let month = dateOfBirth["month"], let dayOfMonth = dateOfBirth["dayOfMonth"] {
                            if let date = RMUtility.getDateFromYearMonthDay(year: year, month: month+1, day: dayOfMonth) {
                                userProfile.birthday = date
                            }
                        }
                    }
                    
                    //greeting_name
                    if let greetingNameJsonString = responseDics["greeting_name"] as? String, !greetingNameJsonString.isEmpty {
                        let greetingNameDic = RMUtility.parseJSONToDictionary(inputString: greetingNameJsonString)
                        userProfile.greetingNameUri = greetingNameDic!["uri"] as? String
                        userProfile.greetingNameDuration = greetingNameDic!["duration"] as! Int32
                    }
                    
                    //greeting_welcome
                    if let greetinWelcomeJsonString = responseDics["greeting_welcome"] as? String, !greetinWelcomeJsonString.isEmpty {
                        let greetingWelcomeDic = RMUtility.parseJSONToDictionary(inputString: greetinWelcomeJsonString)
                        userProfile.greetingWelcomeUri = greetingWelcomeDic!["uri"] as? String
                        userProfile.greetingWelcomeDuration = greetingWelcomeDic!["duration"] as! Int32
                    }
                    
                    //Email Notifications voicemail email time_zone vsms_enabled mc_enabled
                    if let emailNotificationsString = responseDics["voicemail"] as? String, !emailNotificationsString.isEmpty {
                        let emailNotificationDic = RMUtility.parseJSONToDictionary(inputString: emailNotificationsString)
                        userProfile.vEmail = emailNotificationDic!["email"] as? String
                        userProfile.timeZone = emailNotificationDic!["time_zone"] as? String
                        userProfile.vsmsEnabled = emailNotificationDic!["vsms_enabled"] as! Bool
                        userProfile.mcEnabled = emailNotificationDic!["mc_enabled"] as! Bool
                    }

                    //Custom Settings
                    var phoneDetailsDic: [String: Any]?
                    if let customSettingsJsonString = responseDics["custom_settings"] as? String, !customSettingsJsonString.isEmpty {
                        let customSettings = RMUtility.parseJSONToArrayOfDictionary(inputString: customSettingsJsonString)
                        
                        for customSetting in customSettings! {
                            if let recordingTime = customSetting["recording_time"] as? String {
                                userProfile.recordingTime = recordingTime
                            } else if let storageLocation = customSetting["storage_location"] as? String {
                                userProfile.storageLocation = storageLocation
                            } else if let recordMode = customSetting["default_record_mode"] as? String {
                                userProfile.recordMode = recordMode
                            } else if let phoneDetailsJson = customSetting["ph_dtls"] as? String {
                                phoneDetailsDic = RMUtility.parseJSONToDictionary(inputString: phoneDetailsJson)
                            }
                        }
                    }

                    //Update UserContacts
                    for userContact in (responseDics["user_contacts"] as! [[String: Any]]) {
                        //Check for existing Contact, if not present, then create new one
                        var updatedUserContact: UserContact
                        let predicate = NSPredicate(format: "contactID == %@", userContact["contact_id"] as! String)
                        if let foundUserContact = userProfile.userContacts?.filtered(using: predicate).first as? UserContact {
                            updatedUserContact = foundUserContact
                        } else {
                            updatedUserContact = NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.USERCONTACT, into: context) as! UserContact
                            userProfile.addToUserContacts(updatedUserContact)
                        }
                        
                        updatedUserContact.contactType = userContact["contact_type"] as? String
                        updatedUserContact.contactID = userContact["contact_id"] as? String
                        updatedUserContact.countryCode = userContact["country_code"] as? String
                        updatedUserContact.isPrimary = userContact["is_primary"] as! Bool
                        updatedUserContact.bloggerID = userContact["blogger_id"] as! Int64
                        
                        //Phone Details
                        if let phoneDetail = phoneDetailsDic?[updatedUserContact.contactID!] as? [String: Any] {
                            updatedUserContact.titleName = phoneDetail["title_nm"] as? String
                            updatedUserContact.imageName = phoneDetail["img_nm"] as? String
                        }
                        
                        //Format Number
                        if updatedUserContact.countryImageData == nil {
                            do {
                                let number = try PhoneNumberKit().parse(updatedUserContact.contactID!)
                                let formatedNumber = PhoneNumberKit().format(number, toType: .international)
                                updatedUserContact.formatedNumber = formatedNumber
                                
                                if let regionCode = PhoneNumberKit().getRegionCode(of: number) {
                                    DispatchQueue.main.sync(execute: {
                                        let country =  (CountryPickerView()).countries.filter({ $0.code == regionCode })
                                        updatedUserContact.countryName = country.first?.name
                                        updatedUserContact.countryImageData = country.first?.countryImageData!
                                    })
                                }
                            } catch { print("PhonenumberKit parser error") }
                        }
                        
                        //If this is primary number request for carrier list
                        if updatedUserContact.isPrimary {
                            userProfile.primaryContact = updatedUserContact
                        }
                        
                        if let error = saveBlock(true) {
                            print("Coredata save error. \(error.localizedDescription)")
                        }
                    }
                }, andInMainThread: {
                    if Constants.appDelegate.userProfile?.primaryContact?.carriers == nil || Constants.appDelegate.userProfile?.primaryContact?.carriers?.count == 0 {
                        ServiceRequest.shared.startRequestForListOfCarriers(forUserContact: (Constants.appDelegate.userProfile?.primaryContact!)!, completionHandler: { (success) in
                            guard success else { return }
                        })
                    }
                    completionHandler(true)
                })
                            
        }
    }
}

// MARK: - LIST_CARRIERS API
extension ServiceRequest {
    
    func startRequestForListOfCarriers(forUserContact contact: UserContact, completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.LIST_CARRIERS,
                                     "country_code": contact.countryCode!,
                                     "fetch_voicemails_info": true]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Carrier List", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
                    let userProfile = RMUtility.getProfileforConext(context: context)!
                    
                    //Handle Resonse
                    let predicate = NSPredicate(format: "contactID contains[c] %@", contact.contactID!)
                    //Filter exact userContact from profile for which carrierList to be update
                    let userContact = userProfile.userContacts?.filtered(using: predicate).first as! UserContact
                    
                    //Update New Carriers
                    for remoteCarrier in (responseDics["country_list"] as! [[String: Any]]) {
                        
                        let updatedCarrier = NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.CARRIER, into: context) as! Carrier
                        updatedCarrier.carrierName = remoteCarrier["carrier_name"] as? String
                        updatedCarrier.vsmsNodeID = remoteCarrier["vsms_node_id"] as! Int16
                        updatedCarrier.countryCode = remoteCarrier["country_code"] as? String
                        updatedCarrier.networkID = remoteCarrier["network_id"] as? String
                        updatedCarrier.networkName = remoteCarrier["network_name"] as? String
                        updatedCarrier.ussdString = remoteCarrier["ussd_string"] as? String
                        
                        if let jsonString = remoteCarrier["ussd_string"] as? String, !jsonString.isEmpty {
                            let ussdValues = RMUtility.parseJSONToDictionary(inputString: jsonString)
                            if let international = ussdValues!["rm_intl"] as? Bool {
                                updatedCarrier.reachMeIntl = international
                            }
                            if let home = ussdValues!["rm_home"] as? Bool {
                                updatedCarrier.reachMeHome = home
                            }
                            if let voiceMail = ussdValues!["rm_vm"] as? Bool {
                                updatedCarrier.reachMeVoiceMail = voiceMail
                            }
                            updatedCarrier.actiUNCF = ussdValues!["acti_uncf"] as? String
                            updatedCarrier.deactiUNCF = ussdValues!["deacti_uncf"] as? String
                            updatedCarrier.actiAll = ussdValues!["acti_all"] as? String
                            updatedCarrier.deactiBoth = ussdValues!["deacti_both"] as? String
                            updatedCarrier.actiCNF = ussdValues!["acti_cnf"] as? String
                            updatedCarrier.deactiCNF = ussdValues!["acti_uncf"] as? String
                            updatedCarrier.additionalActiInfo = ussdValues!["add_acti_info"] as? String
                            if let hlrStatus = ussdValues!["is_hlr_callfwd_enabled"] as? Bool {
                                updatedCarrier.isHLREnabled = hlrStatus
                            }
                            if let voipStatus = ussdValues!["voip_enabled"] as? Bool {
                                updatedCarrier.isVOIPEnabled = voipStatus
                            }
                            
                            if updatedCarrier.reachMeIntl || updatedCarrier.reachMeHome || updatedCarrier.reachMeVoiceMail {
                                updatedCarrier.isReachMeSupport = true
                            }
                            if !updatedCarrier.reachMeIntl && !updatedCarrier.reachMeHome && !updatedCarrier.reachMeVoiceMail {
                                updatedCarrier.networkName = "Not supported"
                            }
                        }
                        
                        if let carrierInfoList = remoteCarrier["carrier_info"] {
                            for (key, value) in carrierInfoList as! [String: Any] {
                                switch key {
                                case "logo_home_url":
                                    updatedCarrier.logoHomeURL = value as? String
                                case "logo_support_url":
                                    updatedCarrier.logoSupportURL = value as? String
                                case "logo_theme_color":
                                    updatedCarrier.logoThemeColor = value as? String
                                case "logo":
                                    updatedCarrier.logoURL = value as? String
                                case "in_app_promo":
                                    if let inAppPromo = value as? [[String: Any]] {
                                        inAppPromo.forEach({ (inAppPromoDisc) in
                                            // inAppPromoDisc["show_image"] as! Bool
                                            updatedCarrier.inAppPromoImageURL = inAppPromoDisc["image_url"] as? String
                                        })
                                    }
                                    
                                default:
                                    break
                                }
                            }
                        }
                        
                        userContact.addToCarriers(updatedCarrier)
                    }
                }, andInMainThread: {
                    completionHandler(true)
                })
        }
    }
}

// MARK: - FETCH_SETTINGS API
extension ServiceRequest {
    
    func startRequestForFetchSettings(completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.FETCH_SETTINGS,
                                     "fetch_voicemails_info": true]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Fetch Settings", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                //Handle response Data
                self.coreDataStack.deleteAllRecordsForEntity(entity: Constants.EntityName.SUPPORT_CONTACT)
                self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
                    let userProfile = RMUtility.getProfileforConext(context: context)!
                    
                    let supportContactJsonString = responseDics["iv_support_contact_ids"] as? String
                    let contactIDs = RMUtility.parseJSONToArrayOfDictionary(inputString: supportContactJsonString!)
                    for (index, contactID) in (contactIDs?.enumerated())! {
                        let supportContact = NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.SUPPORT_CONTACT, into: context) as! SupportContact

                        supportContact.userID = contactID["iv_user_id"] as? String
                        supportContact.phone = contactID["phone"] as? String
                        supportContact.profilePicURL = contactID["profile_pic_uri"] as? String
                        supportContact.thumbnailPicURL = contactID["thumbnail_profile_pic_uri"] as? String
                        supportContact.isShowIVUser = contactID["show_as_iv_user"] as! Bool
                        
                        switch index {
                        case 0:
                            supportContact.supportType = contactID["support_catg"] as? String
                            supportContact.supportID = contactID["support_catg_id"] as? String
                            supportContact.isSendEmail = contactID["support_send_email"] as! Bool
                            supportContact.isSendIV = contactID["support_send_iv"] as! Bool
                            supportContact.isSendSMS = contactID["support_send_sms"] as! Bool
                        case 1:
                            supportContact.supportType = contactID["feedback_catg"] as? String
                            supportContact.supportID = contactID["feedback_catg_id"] as? String
                            supportContact.isSendEmail = contactID["feedback_send_email"] as! Bool
                            supportContact.isSendIV = contactID["feedback_send_iv"] as! Bool
                            supportContact.isSendSMS = contactID["feedback_send_sms"] as! Bool
                        default:
                            break
                        }
                        
                        userProfile.addToSupportContacts(supportContact)
                    }
                    
                    //Custom Settings
                    let customSettingsJsonString = responseDics["custom_settings"] as! String
                    let customSettings = RMUtility.parseJSONToArrayOfDictionary(inputString: customSettingsJsonString)
                    for customSetting in customSettings! {
                        
                        if let carrierJsonString = customSetting["carrier"] as? String {
                            let carrier = RMUtility.parseJSONToDictionary(inputString: carrierJsonString)
                            
                            (userProfile.userContacts?.allObjects as? [UserContact])?.forEach({ userContact in
                                
                                if let carrierInfo = carrier![userContact.contactID!] as? [String: Any] {
                                    
                                    if let international = carrierInfo["rm_intl_acti"] as? Bool {
                                        userContact.isReachMeIntlActive = international
                                    }
                                    if let home = carrierInfo["rm_home_acti"] as? Bool {
                                        userContact.isReachMeHomeActive = home
                                    }
                                    if let voiceMail = carrierInfo["vm_acti"] as? Bool {
                                        userContact.isReachMeVoiceMailActive = voiceMail
                                    }
                                    
                                    //Search carrier from carrier list with math of carrier info
                                    if let carrierFound = (userProfile.primaryContact?.carriers?.allObjects as? [Carrier])?.filter({
                                        if let vsmsID = carrierInfo["vsms_id"] as? Int16 {
                                            if $0.networkID == carrierInfo["network_id"] as? String &&
                                                $0.countryCode == carrierInfo["country_cd"] as? String &&
                                                $0.vsmsNodeID == vsmsID {
                                                return true
                                            }
                                        }
                                        return false
                                    }), carrierFound.count > 0 {
                                        userContact.selectedCarrier = carrierFound.first
                                    } else {
                                        if userContact.selectedCarrier == nil {
                                            userContact.selectedCarrier = (NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.CARRIER, into: context) as! Carrier)
                                        }
                                        if let vsms = carrierInfo["vsms_id"] as? Int16 {
                                            userContact.selectedCarrier?.vsmsNodeID = vsms
                                        }
                                        userContact.selectedCarrier?.countryCode = carrierInfo["country_cd"] as? String
                                        userContact.selectedCarrier?.networkID = carrierInfo["network_id"] as? String
                                        userContact.selectedCarrier?.networkName = "Select Your Carrier"
                                    }
                                }
                            })
                        }
                    }

                    //Voicemail Info
                    if let voiceMailInfo = responseDics["voicemails_info"] as? [[String: Any]] {
                        for voiceMail in voiceMailInfo {
                            let predicate = NSPredicate(format: "contactID contains[c] %@", voiceMail["phone"] as! String)
                            let userContact = userProfile.userContacts?.filtered(using: predicate).first as! UserContact
                            
                            if userContact.voiceMailInfo == nil {
                                userContact.voiceMailInfo = (NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.VOICEMAIL, into: context) as! VoiceMail)
                            }
                            
                            userContact.voiceMailInfo?.phoneNumber = voiceMail["phone"] as? String
                            userContact.voiceMailInfo?.carrierCountryCode = voiceMail["carrier_country_code"] as? String
                            userContact.voiceMailInfo?.kvSMSKey = voiceMail["kvsms_key"] as? String
                            userContact.voiceMailInfo?.networkId = voiceMail["network_id"] as? String
                            userContact.voiceMailInfo?.countryVoicemailSupport = voiceMail["country_voicemail_support"] as! Bool
                            if let isEnabled = voiceMail["enabled"] as? Int16 {
                                userContact.voiceMailInfo?.isVoiceMailEnabled = Bool(truncating: isEnabled as NSNumber)
                            }
                            userContact.voiceMailInfo?.availableVocieMailCount = voiceMail["avs_cnt"] as! Int16
                            userContact.voiceMailInfo?.missedCallCount = voiceMail["mca_cnt"] as! Int16
                            userContact.voiceMailInfo?.realVocieMailCount = voiceMail["real_avs_cnt"] as! Int16
                            userContact.voiceMailInfo?.realMissedCallCount = voiceMail["real_mca_cnt"] as! Int16
                            userContact.voiceMailInfo?.latestMessageCount = voiceMail["new_msg_cnt"] as! Int16
                            userContact.voiceMailInfo?.oldMessageCount = voiceMail["old_msg_cnt"] as! Int16
                            userContact.voiceMailInfo?.lastVoiceMailCountTimeStamp = voiceMail["avs_timestamp"] as! Int64
                            userContact.voiceMailInfo?.lastMissedCallTimeStamp = voiceMail["mca_timestamp"] as! Int64
                            userContact.voiceMailInfo?.vSMSNodeId = voiceMail["vsms_node_id"] as! Int16
                            
                            if let jsonString = voiceMail["ussd_string"] as? String, !jsonString.isEmpty {
                                let ussdValues = RMUtility.parseJSONToDictionary(inputString: jsonString)
                                userContact.voiceMailInfo?.actiUNCF = ussdValues!["acti_uncf"] as? String
                                userContact.voiceMailInfo?.deactiUNCF = ussdValues!["deacti_uncf"] as? String
                                userContact.voiceMailInfo?.actiAll = ussdValues!["acti_all"] as? String
                                userContact.voiceMailInfo?.deactiBoth = ussdValues!["deacti_both"] as? String
                                userContact.voiceMailInfo?.actiCNF = ussdValues!["acti_cnf"] as? String
                                userContact.voiceMailInfo?.deactiCNF = ussdValues!["acti_uncf"] as? String
                                userContact.voiceMailInfo?.additionalActiInfo = ussdValues!["add_acti_info"] as? String
                                if let hlrStatus = ussdValues!["is_hlr_callfwd_enabled"] as? Bool {
                                    userContact.voiceMailInfo?.isHLREnabled = hlrStatus
                                }
                                if let voipStatus = ussdValues!["voip_enabled"] as? Bool {
                                    userContact.voiceMailInfo?.isVOIPEnabled = voipStatus
                                }
                                if let rmHome = ussdValues!["rm_home"] as? Bool {
                                    userContact.voiceMailInfo?.rmHome = rmHome
                                }
                                if let rmIntl = ussdValues!["rm_intl"] as? Bool {
                                    userContact.voiceMailInfo?.rmIntl = rmIntl
                                }
                                if let rmVM = ussdValues!["rm_vm"] as? Bool {
                                    userContact.voiceMailInfo?.rmVM = rmVM
                                }
                            }
                            
                            if !(userContact.voiceMailInfo?.countryVoicemailSupport)! {
                                userContact.selectedCarrier?.networkName = "Not supported"
                            }
                        }
                    }
                    
                    //MQTTSettings
                    if userProfile.mqttSettings == nil {
                        userProfile.mqttSettings = (NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.MQTT, into: context) as! MQTT)
                    }
                    userProfile.mqttSettings?.chatTopic = responseDics["chat_topic"] as? String
                    userProfile.mqttSettings?.chatUser = responseDics["chat_user"] as? String
                    userProfile.mqttSettings?.chatPassword = responseDics["chat_password"] as? String
                    userProfile.mqttSettings?.chatHostname = responseDics["chat_hostname"] as? String
                    userProfile.mqttSettings?.chatPortSSL = responseDics["chat_port_ssl"] as? String
                    userProfile.mqttSettings?.mqttHostname = responseDics["mqtt_hostname"] as? String
                    userProfile.mqttSettings?.mqttPassword = responseDics["mqtt_password"] as? String
                    userProfile.mqttSettings?.mqttUser = responseDics["mqtt_user"] as? String
                    userProfile.mqttSettings?.mqttPortSSL = responseDics["mqtt_port_ssl"] as? String
                    userProfile.mqttSettings?.mqttDeviceID = responseDics["iv_user_device_id"] as! Int32
                    
                    //VOIP Info
                    if let voipInfo = responseDics["voip_info"] as? [String: Any] {
                        if userProfile.voipSettings == nil {
                            userProfile.voipSettings = (NSEntityDescription.insertNewObject(forEntityName: Constants.EntityName.VOIP, into: context) as! VOIP)
                        }
                        userProfile.voipSettings?.login = voipInfo["login"] as? String
                        userProfile.voipSettings?.password = voipInfo["pwd"] as? String
                        userProfile.voipSettings?.ipAddress = voipInfo["ip"] as? String
                        if let port = voipInfo["port"] as? Int16 {
                            userProfile.voipSettings?.port = port
                        }
                    }
                    
                }, andInMainThread: {
                    completionHandler(true)
                })
        }
    }
}

// MARK: - GENERATE_VERIFICATION_CODE API
extension ServiceRequest {
    
    func startRequestForGenerateVerificationCode(completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.GENERATE_VERIFICATION_CODE,
                                     "sim_opr_mcc_mnc": (Constants.appDelegate.userProfile?.simMCCMNCNumber)!,
                                     "reg_secure_key": Defaults[.APIRegSecureKey] as Any,
                                     "send_pin_by": "obd"]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON { (response) in

                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                return
                            }

                //Handle response Data
                completionHandler(true)
        }
    }
}

// MARK: - UPDATE_SETTINGS API
extension ServiceRequest {
    
    func startRequestForUpdateSettings(completionHandler:@escaping (Bool) -> Void) {
        
            var carrierDetailsDict = [String: Any]()
            var phoneDetailsDict = [String: Any]()
            (Constants.appDelegate.userProfile?.userContacts?.allObjects as? [UserContact])?.forEach({ userContact in
                let carrierDetails: [String: Any] = ["country_cd": userContact.selectedCarrier?.countryCode as Any,
                                                     "network_id": userContact.selectedCarrier?.networkID as Any,
                                                     "vsms_id": userContact.selectedCarrier?.vsmsNodeID as Any,
                                                     "rm_intl_acti": userContact.isReachMeIntlActive as Any,
                                                     "rm_home_acti": userContact.isReachMeHomeActive as Any,
                                                     "vm_acti": userContact.isReachMeVoiceMailActive as Any]
                carrierDetailsDict[userContact.contactID!] = carrierDetails

                let phoneDetails: [String: Any] = ["img_nm": userContact.imageName as Any,
                                                   "title_nm": userContact.titleName as Any]
                phoneDetailsDict[userContact.contactID!] = phoneDetails
            })

            let carrierDetailsJsonData = try! JSONSerialization.data(withJSONObject: carrierDetailsDict, options: [])
            let carrierDetailsJsonString = String(data: carrierDetailsJsonData, encoding: .utf8)!

            let phoneDetailsJsonData = try! JSONSerialization.data(withJSONObject: phoneDetailsDict, options: [])
            let phoneDetailsJsonString = String(data: phoneDetailsJsonData, encoding: .utf8)!

            let updatedSettingsInfo: [[String: Any]] =
                [["storage_location": Constants.appDelegate.userProfile?.storageLocation as Any],
                 ["default_record_mode": Constants.appDelegate.userProfile?.recordMode as Any],
                 ["recording_time": Constants.appDelegate.userProfile?.recordingTime as Any],
                 ["carrier": carrierDetailsJsonString],
                 ["ph_dtls": phoneDetailsJsonString]]
            var params: [String: Any] = ["cmd": Constants.ApiCommands.UPDATE_SETTINGS,
                                         "custom_settings": updatedSettingsInfo,
                                         "fb_post_enabled": (Constants.appDelegate.userProfile?.fbPostEnabled)!,
                                         "tw_post_enabled": (Constants.appDelegate.userProfile?.twPostEnabled)!]
            params = RMUtility.serverRequestAddCommonData(params: &params)
            let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

            Alamofire.request(Constants.URL_SERVER,
                              method: .post,
                              encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Update Settings", qos: .background)) { (response) in

                                if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                    completionHandler(false)
                                    return
                                }

                                //No Response Data coming for local update
                                completionHandler(true)

            }
        }
}

// MARK: - GENERATE_PASSWORD API
extension ServiceRequest {
    
    func startRequestForGeneratePassword(completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.GENERATE_PASSWORD,
                                     "login_id": (Constants.appDelegate.userProfile?.userID)!]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Genearate Password", qos: .background)) { (response) in

                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                completionHandler(false)
                                return
                            }

                //No Response Data coming for local update
                completionHandler(true)
        }
    }
}

// MARK: - VERIFY_PASSWORD API
extension ServiceRequest {
    
    func startRequestForVerifyPassword(otpString: String, completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.VERIFY_PASSWORD,
                                     "pwd": otpString,
                                     "login_id": (Constants.appDelegate.userProfile?.userID)!,
                                     "device_id": Constants.DEVICE_UUID]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Verify Password", qos: .background)) { (response) in
                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else {
                    completionHandler(false)
                    return
                }

                //Handle response Data
                ServiceRequest.shared.parseCommonResponseforLoginProcess(responseDics: responseDics)

                completionHandler(true)
        }
    }
}

// MARK: - UPDATE_PROFILE_INFO API
extension ServiceRequest {
    
    func startRequestForUpdateProfileInfo(withProfileInfo profileInfo: inout [String: Any], completionHandler:@escaping (Bool) -> Void) {
        
        let params = RMUtility.serverRequestAddCommonData(params: &profileInfo)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Update Profile Info", qos: .background)) { (response) in

                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                completionHandler(false)
                                return
                            }

                //No Response Data coming for local update
                completionHandler(true)
        }
    }
}

// MARK: - MANAGE_USER_CONTACT API
extension ServiceRequest {
    
    func startRequestForManageUserContact(withManagedInfo managedInfo: inout [String: Any], completionHandler:@escaping ([String: Any]?, Bool) -> Void) {
        
        let params = RMUtility.serverRequestAddCommonData(params: &managedInfo)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Manage User Contact", qos: .background)) { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else { return }

                //Handle response Data
                completionHandler(responseDics, true)
        }
    }
}

// MARK: - VOICEMAIL_SETTING API
extension ServiceRequest {
    
    func startRequestForVoicemailSetting(withVoicemailInfo voicemailInfo: inout [String: Any], completionHandler:@escaping (Bool) -> Void) {
        
        let params = RMUtility.serverRequestAddCommonData(params: &voicemailInfo)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Fetch Voicemail Settings", qos: .background)) { (response) in

                response.result.isSuccess ? completionHandler(true) : completionHandler(false)
        }
    }
}

// MARK: - Download Profile Pic
extension ServiceRequest {
    
    func startRequestForDownloadProfilePic(completionHandler:@escaping (Data) -> Void) {
        
        _ =  Alamofire.request((Constants.appDelegate.userProfile?.profilePicURL)!)
            .validate { request, response, imageData in
                self.coreDataStack.performBackgroundTask(inContext: { (context, saveBlock) in
                    let userProfile = RMUtility.getProfileforConext(context: context)!
                    userProfile.profilePicData = imageData
                })
                completionHandler(imageData!)
                return .success
        }
    }
}

// MARK: - Download ImaGE
extension ServiceRequest {
    
    func startRequestForDownloadImage(forURL downloadURL: String, completionHandler:@escaping (Data) -> Void) {
        
        _ =  Alamofire.request(downloadURL)
            .validate { request, response, imageData in
                completionHandler(imageData!)
                return .success
        }
    }
}

// MARK: - USAGE_SUMMARY API
extension ServiceRequest {
    
    func startRequestForUsageSummary(forPhoneNumber number: String, completionHandler:@escaping ([String: Any]?, Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.USAGE_SUMMARY,
                                     "phone": number]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON { (response) in

                //Handle Error
                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else {
                    completionHandler(nil, false)
                    return
                }

                //Handle response Data
                completionHandler(responseDics, true)
        }
    }
}

// MARK: - SIGNOUT API
extension ServiceRequest {
    
    func startRequestForSignOut(completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.SIGN_OUT]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON { (response) in
                
                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                completionHandler(false)
                                return
                            }
                
                //Handle response Data
                completionHandler(true)
        }
    }
}

// MARK: - SET_DEVICEINFO API
extension ServiceRequest {
    
    func startRequestForSetDeviceInfo(deviceToken: String?, voipToken: String?, completionHandler: (() -> Swift.Void)? = nil) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.SET_DEVICEINFO]
        if let dvToken = deviceToken {
            params["cloud_secure_key"] = dvToken
        }
        if let vpToken = voipToken {
            params["voip_cloud_secure_key"] = vpToken
        }
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Set Device Info", qos: .background)) { (response) in
                
                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                return
                            }
                
                            if let dvToken = deviceToken {
                                Defaults[.APICloudeSecureKey] = dvToken
                            }
                            if let vpToken = voipToken {
                                Defaults[.APIVoipSecureKey] = vpToken
                            }

                completionHandler?()
        }
    }
}

// MARK: - FETCH_MESSAGES API
extension ServiceRequest {
    func startRequestForFetchMessages(completionHandler: ((Bool) -> Swift.Void)?) {
        
            let afterMsgID = (Defaults[.APIFetchAfterMsgID] == nil) ? 0 : Defaults[.APIFetchAfterMsgID] as! Int64
            var params: [String: Any] = ["cmd": Constants.ApiCommands.FETCH_MESSAGES,
                                         DefaultsKey<Any>.APIFetchAfterMsgID._key: afterMsgID,
                                         "fetch_max_rows": 1000,
                                         "fetch_opponent_contactids": true]
            params = RMUtility.serverRequestAddCommonData(params: &params)
            let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
            
            Alamofire.request(Constants.URL_SERVER,
                              method: .post,
                              encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Fetch Message", qos: .background)) { (response) in
                                
                                guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else {
                                    completionHandler?(false)
                                    return
                                }
                                
                                ServiceRequest.shared.handleFetchMessagesResponse(responseDics: responseDics)
                                
                                completionHandler?(true)
            }
        }
}

// MARK: - DELETE_MESSAGE API
extension ServiceRequest {
    func startRequestForDeleteMessage(message: Message, completionHandler: ((Bool) -> Swift.Void)?) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.DELETE_MESSAGE,
                                     "msg_id": message.messageID,
                                     "type": message.type!]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Delete Message", qos: .background)) { (response) in
                
                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                DispatchQueue.main.async { completionHandler?(false) }
                                return
                            }
                            
                completionHandler?(true)
        }
    }
}

// MARK: - READ_MESSAGE API
extension ServiceRequest {
    func startRequestForReadMessages(messages: [Message], completionHandler: ((Bool) -> Swift.Void)?) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.READ_MESSAGES,
                                     "msg_ids": messages.map {$0.messageID},
                                     "msg_ids_type": (messages.first?.fromUserType)!]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Read Message", qos: .background)) { (response) in

                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                completionHandler?(false)
                                return
                            }

                completionHandler?(true)
        }
    }
}

// MARK: - STATES_LIST API
extension ServiceRequest {
    
    func startRequestForStatesList(forCountryCode countryCode: String, completionHandler:@escaping ([String: Any]?, Bool) -> Swift.Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.STATE_LIST,
                                     "country_code": countryCode]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)

        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "States List", qos: .background)) { (response) in

                            //Handle Error
                            guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else {
                                completionHandler(nil, false)
                                return
                            }

                            //Handle response Data
                            completionHandler(responseDics, true)
        }
    }
}

// MARK: - UPLOAD_PIC API
extension ServiceRequest {
    
    func startRequestForUploadProfilePic(picData: Data, completionHandler:@escaping (Bool) -> Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.UPLOAD_PIC,
                                     "file_name": (Constants.appDelegate.userProfile?.userID)!,
                                     "file_type": "png"]
        params = RMUtility.serverRequestAddCommonData(params: &params)

        let requestJSON = RMUtility.convertDictionaryToJSONString(dictionary: params)
        Alamofire.upload(multipartFormData: { multipartFormData in
            multipartFormData.append(picData,
                                     withName: (Constants.appDelegate.userProfile?.userID)!,
                                     fileName: (Constants.appDelegate.userProfile?.userID)!,
                                     mimeType: "")
        }, usingThreshold: UInt64.init(),
          to: Constants.URL_SERVER,
          method: .post,
          headers: ["data": requestJSON],
          encodingCompletion: { encodingResult in
            switch encodingResult {
            case .success(let upload, _, _):
                upload.responseJSON { response in
                    if response.result.isSuccess {
                        completionHandler(true)
                    } else {
                        completionHandler(false)
                    }
                    //debugPrint(response)
                }
            case .failure(let encodingError):
                print(encodingError)
                completionHandler(false)
            }
        })
    }
}

// MARK: - ENQUIRE_IV_USERS API
extension ServiceRequest {
    
    func startRequestForEnquireIVUsers(contactList: [String], completionHandler:@escaping ([String: Any]?, Bool) -> Swift.Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.ENQUIRE_IV_USERS,
                                     "contact_ids": contactList,
                                     "fetch_pic_uri_type": 1]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Enquire IV Users", qos: .background)) { (response) in
                            
                            //Handle Error
                            guard let responseDics = ServiceRequest.shared.handleserviceError(response: response) else {
                                completionHandler(nil, false)
                                return
                            }

                            completionHandler(responseDics, true)
        }
    }
}

// MARK: - FRIEND INVITE API
extension ServiceRequest {
    
    func startRequestForInviteFriend(inviteList: [[String: String]], completionHandler:@escaping (Bool) -> Swift.Void) {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.SEND_TEXT,
                                     "contact_ids": inviteList,
                                     "msg_type": "t",
                                     "type": "inv",
                                     "fetch_msgs": false,
                                     "msg_text": "Hello",
                                     "guid": "\(UUID().uuidString)-\(Constants.DEVICE_UUID)"]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON { (response) in
                            
                            //Handle Error
                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                completionHandler(false)
                                return
                            }
                            
                            completionHandler(true)
        }
    }
}
// MARK: - FETCH_USER_CONTACTS API
extension ServiceRequest { //NOTE: As i observs, all the response parameters of this API are present in "Get Proafile Info" API, since we are saving profile info response so this is no need
    
    func startRequestForFetchUserContacts() {
        
        var params: [String: Any] = ["cmd": Constants.ApiCommands.FETCH_USER_CONTACTS,
                                    "IV_USER_ID": Defaults[.APIIVUserIDKey],
                                    "device_id": Constants.DEVICE_UUID,
                                    "user_secure_key": Defaults[.APIUserSecureKey] as Any]
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON { (response) in
                
                            if ServiceRequest.shared.handleserviceError(response: response) == nil {
                                return
                            }

        }
    }
}

open class ServiceRequestBackground: NSObject {
    override init() { }
    
    func startRequestForFetchMessages(completionHandler:@escaping (Bool) -> Void) {
        
        let afterMsgID = (Defaults[.APIFetchAfterMsgID] == nil) ? 0 : Defaults[.APIFetchAfterMsgID] as! Int64
        var params: [String: Any] = ["cmd": Constants.ApiCommands.FETCH_MESSAGES,
                                     DefaultsKey<Any>.APIFetchAfterMsgID._key: afterMsgID,
                                     "status": "bg",
                                     "fetch_max_rows": 500]  //Check latter for param "fetch_opponent_contactids"
        params = RMUtility.serverRequestAddCommonData(params: &params)
        let payload = RMUtility.serverRequestConstructPayloadFor(params: params)
        
        Alamofire.request(Constants.URL_SERVER,
                          method: .post,
                          encoding: payload).validate().responseJSON(queue: DispatchQueue(label: "Fetch Message Background", qos: .background)) { (response) in
                
                guard response.result.isSuccess else {completionHandler(false); return }
                
                guard let responseDics = response.result.value as? [String: Any] else {completionHandler(false); return }
                guard (responseDics["status"] as! String) != "error" else {completionHandler(false); return }
                
                ServiceRequest.shared.handleFetchMessagesResponse(responseDics: responseDics)
                completionHandler(true)
        }
    }
}

// MARK: - MQTTSessionDelegate
extension ServiceRequest: MQTTSessionDelegate {
    
    public func mqttDidReceive(message data: Data, in topic: String, from session: MQTTSession) {
        ServiceRequest.shared.startRequestForFetchMessages(completionHandler: nil)
        
        //Parse Data to show Local Notification
        var result: [String: Any]!
        do {
            result = try JSONSerialization.jsonObject(with: data, options: .mutableContainers) as! [String: Any]
        } catch { print("Error in JSON Parsing of MQTT Received Data") }
        
        var subtitle: String!
        if let apnsInfo = result["aps"] as? [String: Any] {
            subtitle = (apnsInfo["alert"] as! [String: Any])["body"] as! String
            
        } else if let message = (result["msgs"] as? [[String: Any]])?.first, (message["msg_flow"] as! String) == "r" {
            
            let senderName = (message["sender_id"] as? String) != nil ? (message["sender_id"] as! String) : message["from_phone_num"] as! String
            if let contentType = message["msg_content_type"] as? String {
                if contentType == "t" {
                    if let messageType = message["type"] as? String, messageType == "mc" {
                        if let messageSubType = message["msg_subtype"] as? String, messageSubType == "ring" {
                            subtitle = "\(senderName): Ring Missed Call"
                        } else {
                            subtitle = "\(senderName): Missed Call"
                        }
                    } else {
                        subtitle = "\(senderName): \(message["msg_content"] as! String)"
                    }
                } else if contentType == "a" {
                    subtitle = "\(senderName): Voice Message"
                } else if contentType == "i" {
                    subtitle = "\(senderName): Image"
                }
            }
        }
        
        if subtitle != nil {
            let content = UNMutableNotificationContent()
            content.title = "ReachMe"
            // content.subtitle = subtitle
            content.body = subtitle
            content.sound = UNNotificationSound(named: "InstavoiceNotificationTone")
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.01, repeats: false)
            let request = UNNotificationRequest(identifier: "MQTTLocalNotificationIdentifier", content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
        
    }
    
    public func mqttDidDisconnect(session: MQTTSession) {
        
    }
    
    public func mqttSocketErrorOccurred(session: MQTTSession) {
        print("MQTT Socket Error Occurred")
    }
    
}
