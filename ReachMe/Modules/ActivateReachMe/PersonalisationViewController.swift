//
//  PersonalisationViewController.swift
//  ReachMe
//
//  Created by Sachin Kumar Patra on 3/7/18.
//  Copyright © 2018 sachin. All rights reserved.
//

import UIKit
import SwiftyUserDefaults
import Alamofire

class PersonalisationViewController: UITableViewController {

    private let coreDataStack = Constants.appDelegate.coreDataStack

    @IBOutlet weak var nameTextField: UITextField!
    @IBOutlet weak var emailTextField: UITextField!
    @IBOutlet weak var warningLabel: UILabel!
    @IBOutlet weak var profileImageView: UIImageView!
    @IBOutlet weak var ringtoneLabel: UILabel!
    
    fileprivate lazy var imagePicker: UIImagePickerController = {
        $0.allowsEditing = true
        $0.sourceType = .photoLibrary
        return $0
    }(UIImagePickerController())
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.setHidesBackButton(true, animated: false)
        Defaults[.IsPersonalisation] = true
        Defaults[.IsOnBoarding] = false
        imagePicker.delegate = self
        
        nameTextField.text = Constants.appDelegate.userProfile?.userName
        emailTextField.text = Constants.appDelegate.userProfile?.emailID
        if let profilePicData = Constants.appDelegate.userProfile?.profilePicData,
            let profileImage = UIImage(data: profilePicData) {
            profileImageView.image = profileImage
            
        } else {// If image not downloaded yet, then dwonload once
            ANLoader.showLoading("", disableUI: true)
            ServiceRequest.shared.startRequestForDownloadProfilePic(completionHandler: { (imageData) in
                ANLoader.hide()
                if let profileImage = UIImage(data: imageData) {
                    DispatchQueue.main.async {
                        self.profileImageView.image = profileImage
                    }
                }
            })
        }
        ringtoneLabel.text =  Defaults[.isRingtoneSet] ? "   iPhone" : "   ReachMe"
        
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        view.endEditing(true)
        guard indexPath.row == 2 else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        
        let ringToneVC = SingleSelectionTableViewController(with: .ringTone)
        ringToneVC.delegate = self
        navigationController?.pushViewController(ringToneVC, animated: true)
    }

    // MARK: - Button Actions
    @IBAction func cameraButtonClicked(_ sender: UIButton) {
        present(imagePicker, animated: true, completion: nil)
    }
    
    @IBAction func onSaveButtonClicked(_ sender: UIBarButtonItem) {
        
        if (nameTextField.text?.isEmpty)! || (emailTextField.text?.isEmpty)! {
            warningLabel.text = "Name & Email Address is Required"
            warningLabel.textColor = .red

        } else if !(emailTextField.text?.isValidEmail())! {
            RMUtility.showAlert(withMessage: "Enter Valid Email Address")

        } else {
            guard RMUtility.isNetwork() else {
                RMUtility.showAlert(withMessage: "NET_NOT_AVAILABLE".localized)
                return
            }

            //Saving local DB
            Constants.appDelegate.userProfile?.userName = nameTextField.text
            Constants.appDelegate.userProfile?.emailID = emailTextField.text

            //Update server
            ANLoader.showLoading("", disableUI: true)
            var params: [String: Any] = ["cmd": Constants.ApiCommands.UPDATE_PROFILE_INFO,
                                         "screen_name": Constants.appDelegate.userProfile?.userName as Any,
                                         "email": Constants.appDelegate.userProfile?.emailID as Any]
            ServiceRequest.shared.startRequestForUpdateProfileInfo(withProfileInfo: &params) { (success) in
                guard success else { return }
                
                if let data = UIImagePNGRepresentation(self.profileImageView.image!) {
                    ServiceRequest.shared.startRequestForUploadProfilePic(picData: data, completionHandler: { (successUpload) in
                        if successUpload {
                            Constants.appDelegate.userProfile?.profilePicData = data
                        }
                        Defaults[.IsPersonalisation] = false
                        Defaults[.IsLoggedIn] = true
                        ServiceRequest.shared.connectMQTT()

                        self.coreDataStack.saveContexts(withCompletion: { (error) in
                            ANLoader.hide()
                            RMUtility.showdDashboard()
                        })
                    })
                }
            }
        }
    }
}

// MARK: - ImagePicker delegate
extension PersonalisationViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String: Any]) {
        
        let assetPath = info[UIImagePickerControllerReferenceURL] as! NSURL
        let pathExtension = assetPath.pathExtension! as CFString
        let isvalid = RMUtility.isValidImageforServerUpload(pathExtension: pathExtension)
       
        picker.dismiss(animated: true) {
            guard isvalid else {
                RMUtility.showAlert(withMessage: "Unsupported image type: \(pathExtension)")
                return
            }
            
            let selectedImage = info[UIImagePickerControllerEditedImage] as! UIImage
            self.profileImageView.image = selectedImage
        }        
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismiss(animated: true, completion: nil)
    }
}

// MARK: - TextField delegate
extension PersonalisationViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        
        if range.location == 0, string == " " { //Block leading space
            return false
        }
        
        return true
    }
}

// MARK: - SingleSelectionDelegate
extension PersonalisationViewController: SingleSelectionDelegate {
    func onSelection(_ selectionType: SelectionType) {
        switch selectionType {
        case .ringTone:
            ringtoneLabel.text =  Defaults[.isRingtoneSet] ? "   iPhone" : "   ReachMe"
            
        case .notificationTone:
            break
        }
    }
}
