//
//  ViewController.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/2/24.
//

import UIKit
import Metal

// For Module A: Handles the display of labels based on updates of two loudest tones from FFT
class ModuleAViewController: UIViewController {

    /// Setup audio model
    let audio = AudioModel(buffer_size: AudioConstants.AUDIO_BUFFER_SIZE)
    
    /// For periodically handling label updates
    var timer: Timer? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBOutlet weak var freqOneLabel: UILabel!
    @IBOutlet weak var freqTwoLabel: UILabel!
    
    /// Starts processing audio when navigating to ViewController
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        /// Start up the audio model here, querying microphone
        /// withFps: preferred number of FFT calculations per second
        audio.startMicrophoneProcessingModuleA(withFps: 20)
        audio.play()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.updateLabels()
        }
    }
    
    /// Pauses when navigating away from ViewController
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        
        audio.stop()
        timer?.invalidate()
    }
    
    // Updates largest and second-largest frequency labels with largest and second-largest tones from audio model
    private func updateLabels() {
        freqOneLabel.text = "Frequency 1: \(audio.twoLargestFreqs[0].frequency > -1.0 ? audio.twoLargestFreqs[0].frequency.description : "Noise") (Hz)"
        freqTwoLabel.text = "Frequency 2: \(audio.twoLargestFreqs[1].frequency > -1.0 ? audio.twoLargestFreqs[1].frequency.description : "Noise") (Hz)"
    }
}
