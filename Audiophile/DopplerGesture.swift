//
//  DopplerGesture.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/14/24.
//

import Foundation

// Accounts for all cases tied to recognizing Doppler Shift gestures for Module B
enum DopplerGesture: String {
    /// Used for preventing changes from frequency or volume sliders from registering as Doppler Shift gestures
    case unavailable = "Changing Parameters"
    
    /// Used when establishing history of prior FFT frames for noise reference
    case calibrating = "Calibrating Basline"
    
    case none = "Not Gesturing"
    case away = "Gesturing Away"
    case toward = "Gesturing Toward"
}
