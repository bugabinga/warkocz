/* Minimal TrueType/SFNT grayscale module registration for the vendored
 * FreeType subset. Derived from upstream build requirements; upstream
 * sources remain unmodified.
 */
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
