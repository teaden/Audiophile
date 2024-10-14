//
//  ViewController.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/2/24.
//

import UIKit
import Metal

class ModuleAViewController: UIViewController {

    // setup audio model
    let audio = AudioModel(buffer_size: AudioConstants.AUDIO_BUFFER_SIZE)
    
    var timer: Timer? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBOutlet weak var freqOneLabel: UILabel!
    @IBOutlet weak var freqTwoLabel: UILabel!
    
    // Play when navigating to ViewController
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // start up the audio model here, querying microphone
        audio.startMicrophoneProcessing(withFps: 20) // preferred number of FFT calculations per second
        audio.play()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.updateLabels()
        }
    }
    
    // Pause when navigating away from ViewController
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        
        audio.stop()
        timer?.invalidate()
    }
    
    private func updateLabels() {
        freqOneLabel.text = "Frequency 1: \(audio.twoLargestFreqs[0].frequency > -1.0 ? audio.twoLargestFreqs[0].frequency.description : "Noise") (Hz)"
        
        freqTwoLabel.text = "Frequency 2: \(audio.twoLargestFreqs[1].frequency > -1.0 ? audio.twoLargestFreqs[1].frequency.description : "Noise") (Hz)"
    }
}
