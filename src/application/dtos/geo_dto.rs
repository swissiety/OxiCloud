//! DTOs for the "Places" (photo map) feature.

use serde::Serialize;
use utoipa::ToSchema;

/// A geographic bounding box in decimal degrees.
#[derive(Debug, Clone, Copy)]
pub struct GeoBounds {
    pub west: f64,
    pub south: f64,
    pub east: f64,
    pub north: f64,
}

/// A clustered group of geotagged photos within one aggregation cell.
#[derive(Debug, Clone, Serialize, ToSchema)]
pub struct GeoCluster {
    /// Cluster centroid longitude.
    pub lng: f64,
    /// Cluster centroid latitude.
    pub lat: f64,
    /// Number of photos in the cluster.
    pub count: i64,
    /// A representative photo id, for the cluster thumbnail.
    pub sample_file_id: String,
}
