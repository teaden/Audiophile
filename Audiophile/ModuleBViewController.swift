//
//  ModuleBViewController.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/14/24.
//

import UIKit

class ModuleBViewController: UIViewController {
    
    @IBOutlet weak var userView: UIView!
    @IBOutlet weak var freqLabel: UILabel!
    @IBOutlet weak var volLabel: UILabel!
    
    // setup audio model
    let audio = AudioModel(buffer_size: AudioConstants.AUDIO_BUFFER_SIZE)
    
    lazy var graph:MetalGraph? = {
        return MetalGraph(userView: self.userView)
    }()
    
    var timer: Timer? = nil
    
    private let freqStep: Float = 50
    
    @IBAction func changeFrequency(_ sender: UISlider) {
        sender.setValue(round(sender.value / freqStep) * freqStep, animated: false)
        self.audio.frequencyModuleB = sender.value
        freqLabel.text = "Frequency: \(sender.value)"
    }
    
    @IBAction func changeVolume(_ sender: UISlider) {
        self.audio.volumeModuleB = sender.value
        volLabel.text = "Volume: \(sender.value)"
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if let graph = self.graph{
            graph.setBackgroundColor(r: 0, g: 0, b: 0, a: 1)
            
            graph.addGraph(withName: "time",
                numPointsInGraph: AudioConstants.AUDIO_BUFFER_SIZE)
            
            graph.addGraph(withName: "fftZoomed",
                            shouldNormalizeForFFT: true,
                            numPointsInGraph: 300)
            
            graph.makeGrids() // add grids to graph
        }
        
        // start up the audio model here, querying microphone
        audio.startAudioIoProcessingModuleB(withFps: 20) // preferred number of FFT calculations per second

        audio.play()
        
        // run the loop for updating the graph peridocially
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.updateGraph()
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        
        timer?.invalidate()
        graph?.teardown()
        graph = nil
        audio.stop()
        super.viewDidDisappear(animated)
    }
    
    
    
    // periodically, update the graph with refreshed FFT Data
    func updateGraph(){
        
        if let graph = self.graph {
            
            graph.updateGraph(
                data: self.audio.timeSamples,
                forKey: "time"
            )
            
            graph.updateGraph(
                data: self.audio.fftSamples,
                forKey: "fftZoomed"
            )
            
            // BONUS: show the zoomed FFT
            // we can start at about 150Hz and show the next 300 points
            // actual Hz = f_0 * N/F_s
//            let minfreq = min(min(frequency1,frequency2),frequency3)
//            let startIdx:Int = (Int(minfreq)-50) * AudioConstants.AUDIO_BUFFER_SIZE/audio.samplingRate
//            let subArray:[Float] = Array(self.audio.fftData[startIdx...startIdx+300])
//            graph.updateGraph(
//                data: subArray,
//                forKey: "fftZoomed"
//            )
            
            
        }
        
    }

}
