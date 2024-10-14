//
//  ModuleBViewController.swift
//  Audiophile
//
//  Created by Tyler Eaden on 10/14/24.
//

import UIKit

class ModuleBViewController: UIViewController {
    
    @IBOutlet weak var userView: UIView!
    
    // setup audio model
    let audio = AudioModel(buffer_size: AudioConstants.AUDIO_BUFFER_SIZE)
    
    lazy var graph:MetalGraph? = {
        return MetalGraph(userView: self.userView)
    }()
    

    // Part One: Table It #2 (1 pts) - Pause when navigating away from and play when navigating to Viewcontroller
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        audio.togglePlaying()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let graph = self.graph{
            graph.setBackgroundColor(r: 0, g: 0, b: 0, a: 1)
            
            // add in graphs for display
            // note that we need to normalize the scale of this graph
            // because the fft is returned in dB which has very large negative values and some large positive values
            
            
            graph.addGraph(withName: "fft",
                            shouldNormalizeForFFT: true,
                            numPointsInGraph: AudioConstants.AUDIO_BUFFER_SIZE/2)
            
            // Part Two: Equalize It #1 (0.25 pts) - Add another graph to the view that is 20 points long
            graph.addGraph(withName: "equalize_fft",
                            shouldNormalizeForFFT: true,
                            numPointsInGraph: 20)
            
            graph.addGraph(withName: "time",
                numPointsInGraph: AudioConstants.AUDIO_BUFFER_SIZE)
            
            
            
            graph.makeGrids() // add grids to graph
        }
        
        // start up the audio model here, querying microphone
        // audio.startMicrophoneProcessing(withFps: 20) // preferred number of FFT calculations per second
        
        // start up the audio model here, querying file
        audio.startProcesingAudioFileForPlayback(withFps: 20)
        
        // run the loop for updating the graph peridocially
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            self.updateGraph()
        }
       
    }
    
    
    // Part One: Table It #2 (1 pts) - Pause when navigating away from and play when navigating to Viewcontroller
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(true)
        audio.togglePlaying()
    }
    
    // periodically, update the graph with refreshed FFT Data
    func updateGraph(){
        
        if let graph = self.graph{
            graph.updateGraph(
                data: self.audio.fftData,
                forKey: "fft"
            )
            
            // Part Two: Equalize It #4 (1 pts) - Graph the 20 point array after you have filled it in by adding using MetalGraph
            graph.updateGraph(
                data: self.audio.fftTwentyData,
                forKey: "equalize_fft"
            )
            
            graph.updateGraph(
                data: self.audio.timeData,
                forKey: "time"
            )
            
            
            
        }
        
    }

}
