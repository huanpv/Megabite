//
//  ImageProcessor.m
//  FoodFace
//
//  Created by Aaron on 02/01/2016.
//  Copyright © 2016 Aaron. All rights reserved.
//

#import "ImageProcessor.h"
#import "ImageProcessorResult.h"
#import "ImageHelper.h"
#import <opencv2/opencv.hpp>
#import "ContourAnalyser.h"
#import "Polygon.h"
#import "PolygonHelper.h"

@implementation ImageProcessor {
    UIImage *inputImage;
    UIImage *croppedImage;
    cv::Mat imageMatrix;
    cv::Mat imageMatrixAll;
    cv::Mat imageMatrixFiltered;
    cv::Mat imageMatrixOriginal;
    std::vector<std::vector<cv::Point>> allContours;
    std::vector<std::vector<cv::Point>> filteredContours;
    NSMutableArray *contourImages;
    NSMutableArray *extractedPolygons;
}

- (id)initWithImage:(UIImage*)image {
    self = [super init];
    if (self) {
        inputImage = image;
    }
    return self;
}

- (void)run:(NSDictionary*)options completion:(void (^)(ImageProcessorResult *result))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        ImageProcessorResult *results = [self run:options];
    
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results);
        });

    });
}

- (ImageProcessorResult*)run:(NSDictionary*)options {
    ImageProcessorResult *prepareImageResult = [ImageProcessorResult new];
    prepareImageResult = [self prepareImage];
    
    ImageProcessorResult *findContoursResult = [ImageProcessorResult new];
    findContoursResult = [self findContours:[options[@"arcLengthMultiplier"] floatValue]];
    
    ImageProcessorResult *filterContoursResult = [ImageProcessorResult new];
    filterContoursResult = [self filterContours];
    
    ImageProcessorResult *extractContourBoundingBoxImagesResult = [ImageProcessorResult new];
    extractContourBoundingBoxImagesResult = [self extractContourBoundingBoxImages];
    
    ImageProcessorResult *boundingBoxImagesToPolygonsResult = [ImageProcessorResult new];
    boundingBoxImagesToPolygonsResult = [self boundingBoxImagesToPolygons];
    
    ImageProcessorResult *placePolygonsOnTargetTemplateResult = [ImageProcessorResult new];
    placePolygonsOnTargetTemplateResult = [self placePolygonsOnTargetTemplate:[options[@"maxNumPolygonRotations"] floatValue]];
    
    return [self results:@[prepareImageResult.images.firstObject,
                           extractContourBoundingBoxImagesResult.images,
                           placePolygonsOnTargetTemplateResult.results.firstObject]
                  images:@[]];
}

- (ImageProcessorResult*)prepareImage {
    // Resize the image to 1000x1000 pixels
    croppedImage = [ImageHelper resizeImage:inputImage scaledToSize:CGSizeMake(1000, 1000)];
    
    // Crop the image to the shape of the plate
    croppedImage = [ImageHelper roundedRectImageFromImage:croppedImage size:inputImage.size withCornerRadius:inputImage.size.height/2];
    
    // Convert the image into a matrix
    imageMatrix = [ImageHelper cvMatFromUIImage:croppedImage];
    imageMatrix.copyTo(imageMatrixAll);
    imageMatrix.copyTo(imageMatrixFiltered);
    
    // Keep a copy of the original input image in cv::Mat format
    imageMatrixOriginal = [ImageHelper cvMatFromUIImage:inputImage];
    
    // Return the resized and cropped image
    return [self results:@[] images:@[croppedImage]];
}

- (ImageProcessorResult*)findContours:(float)arcLengthMultiplier {
    // Detect all contours within the image matrix, and filter for those that match detection criteria
    allContours = [ContourAnalyser findContoursInImage:imageMatrixAll arcLengthMultiplier:arcLengthMultiplier];
    
//    // Highlight the contours in the cropped image
//    cv::Mat cvMatWithSquaresAll = [ImageHelper highlightContoursInImage:allContours image:imageMatrixAll];
//    UIImage *highlightedContours = [ImageHelper UIImageFromCVMat:cvMatWithSquaresAll];
//    
    NSMutableArray *debugImages = [ContourAnalyser getDebugImages];
    [debugImages addObject:inputImage];
    
    // Return all debug images (including all contours highlighted on the original image
    return [self results:debugImages images:@[]];
}

- (ImageProcessorResult*)filterContours {
    filteredContours = [ContourAnalyser filterContours:allContours];
    
    // Highlight the contours in the image
    cv::Mat cvMatWithSquaresFiltered = [ImageHelper highlightContoursInImage:filteredContours image:imageMatrixOriginal];
    UIImage *highlightedContours = [ImageHelper UIImageFromCVMat:cvMatWithSquaresFiltered];
    
    // Count the number of filtered contours
    NSNumber *numFilteredContours = [NSNumber numberWithUnsignedLong:filteredContours.size()];
    
    // Return the number of filtered contours, and a debug image of the contours highlighted on the original image
    return [self results:@[numFilteredContours] images:@[highlightedContours]];
}

- (ImageProcessorResult*)extractContourBoundingBoxImages {
    // Extract filtered contours from the cropped image
    cv::vector<cv::Mat> extractedContours = [ImageHelper cutContoursFromImage:filteredContours image:imageMatrix];
    
    // Crop extracted contours to their minimum bounding box, and make background transparent
    contourImages = [ContourAnalyser reduceContoursToBoundingBox:extractedContours];
    
    NSMutableArray *debugImages = [ContourAnalyser getDebugImages];
    
    return [self results:contourImages images:debugImages];
}

- (ImageProcessorResult*)boundingBoxImagesToPolygons {
    // Construct Polygon objects from the extracted images
    extractedPolygons = [NSMutableArray array];
    for (int i = 0; i < contourImages.count; i++) {
        Polygon *polygon = [[Polygon alloc] initWithImage:contourImages[i]];
        [extractedPolygons addObject:polygon];
    }
    
    return [self results:@[extractedPolygons] images:@[]];
}

- (ImageProcessorResult*)placePolygonsOnTargetTemplate:(int)maxNumPolygonRotations {
    // Get the bin Polygons based on the item Polygons we've extracted
    NSArray *binPolygons = [PolygonHelper binPolygonsForTemplateBasedOnItemPolygons:extractedPolygons];
    
    // Sort the polygons by surface area size (largest to smallest)
    NSArray *sortedBinPolygons = [PolygonHelper sortPolygonsBySurfaceArea:binPolygons];
    NSArray *sortedExtractedPolygons = [PolygonHelper sortPolygonsBySurfaceArea:extractedPolygons];
    
    UIImage *outputImage = [UIImage imageNamed:@"EmptyPlate"];
    
    for (int i = 0; i < sortedBinPolygons.count; i++) {
        Polygon *currentBinPolygon = sortedBinPolygons[i];
        Polygon *currentExtractedPolygon = sortedExtractedPolygons[i];
        
        // Find the rotation where the extracted polygon covers the target polygon with the largest surface area coverage
        currentExtractedPolygon = [PolygonHelper rotatePolygonToCoverPolygon:currentExtractedPolygon bin:currentBinPolygon maxNumPolygonRotations:maxNumPolygonRotations];
        
        // Add the polygon to the image at the desired location (based on the polygon centroids)
        outputImage = [PolygonHelper addItemPolygon:currentExtractedPolygon toImage:outputImage atBinPolygon:currentBinPolygon];
    }
    
    // Return the output image containing all polygons rendered on the image
    return [self results:@[outputImage] images:@[]];
}

- (ImageProcessorResult*)results:(NSArray*)results images:(NSArray*)images {
    return [[ImageProcessorResult alloc] initWithResults:results images:images];
}

@end